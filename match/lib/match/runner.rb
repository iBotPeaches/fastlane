require 'fastlane_core/cert_checker'
require 'fastlane_core/provisioning_profile'
require 'fastlane_core/print_table'
require 'spaceship/client'
require 'sigh/module'

require_relative 'generator'
require_relative 'module'
require_relative 'table_printer'
require_relative 'spaceship_ensure'
require_relative 'utils'

require_relative 'storage'
require_relative 'encryption'
require_relative 'profile_includes'
require_relative 'portal_cache'

module Match
  # rubocop:disable Metrics/ClassLength
  class Runner
    attr_accessor :files_to_commit
    attr_accessor :files_to_delete
    attr_accessor :spaceship

    attr_accessor :storage

    attr_accessor :encryption

    attr_accessor :cache

    # The APNs authentication key synced by this run, if `push_auth_key` was set
    attr_accessor :push_auth_key

    # rubocop:disable Metrics/PerceivedComplexity
    def run(params)
      self.files_to_commit = []
      self.files_to_delete = []

      FileUtils.mkdir_p(params[:output_path]) if params[:output_path]

      FastlaneCore::PrintTable.print_values(config: params,
                                             title: "Summary for match #{Fastlane::VERSION}")

      prepare_storage(params)

      unless params[:readonly]
        self.spaceship = SpaceshipEnsure.new(params[:username], params[:team_id], params[:team_name], api_token(params))
        if params[:type] == "enterprise" && !Spaceship::ConnectAPI.client.in_house?
          UI.user_error!("You defined the profile type 'enterprise', but your Apple account doesn't support In-House profiles")
        end
      end

      if params[:app_identifier].kind_of?(Array)
        app_identifiers = params[:app_identifier]
      else
        app_identifiers = params[:app_identifier].to_s.split(/\s*,\s*/).uniq
      end

      # sometimes we get an array with arrays, this is a bug. To unblock people using match, I suggest we flatten
      # then in the future address the root cause of https://github.com/fastlane/fastlane/issues/11324
      app_identifiers = app_identifiers.flatten.uniq

      if spaceship
        # Cache bundle ids, certificates, profiles, and devices.
        self.cache = Portal::Cache.build(
          params: params,
          bundle_id_identifiers: app_identifiers
        )

        # Verify the App ID (as we don't want 'match' to fail at a later point)
        app_identifiers.each do |app_identifier|
          spaceship.bundle_identifier_exists(username: params[:username], app_identifier: app_identifier, cached_bundle_ids: self.cache.bundle_ids)
        end
      end

      # APNs authentication key, before anything else is created so a key match
      # can't create (e.g. with an API key) fails the run before it changes anything
      fetch_push_auth_key(params) if params[:push_auth_key]

      # Certificate
      cert_id = fetch_certificate(params: params, renew_expired_certs: params[:renew_expired_certs])

      # Mac Installer Distribution Certificate
      additional_cert_types = params[:additional_cert_types] || []
      cert_ids = additional_cert_types.map do |additional_cert_type|
        fetch_certificate(params: params, renew_expired_certs: params[:renew_expired_certs], specific_cert_type: additional_cert_type)
      end

      profile_type = Sigh.profile_type_for_distribution_type(
        platform: params[:platform],
        distribution_type: params[:type]
      )

      cert_ids << cert_id
      spaceship.certificates_exists(username: params[:username], certificate_ids: cert_ids, platform: params[:platform], profile_type: profile_type, cached_certificates: self.cache.certificates) if spaceship

      # Provisioning Profiles

      unless params[:skip_provisioning_profiles]
        app_identifiers.each do |app_identifier|
          loop do
            break if fetch_provisioning_profile(params: params,
                                          profile_type: profile_type,
                                        certificate_id: cert_id,
                                        app_identifier: app_identifier,
                                     working_directory: storage.working_directory)
          end
        end
      end

      has_file_changes = self.files_to_commit.count > 0 || self.files_to_delete.count > 0
      if has_file_changes && !params[:readonly]
        self.encryption.encrypt_files if self.encryption
        storage.save_changes!(files_to_commit: self.files_to_commit, files_to_delete: self.files_to_delete)
      end

      # Print a summary table for each app_identifier
      app_identifiers.each do |app_identifier|
        TablePrinter.print_summary(app_identifier: app_identifier, type: params[:type], platform: params[:platform])
      end

      UI.success("All required keys, certificates and provisioning profiles are installed 🙌".green)
    rescue Spaceship::Client::UnexpectedResponse, Spaceship::Client::InvalidUserCredentialsError, Spaceship::Client::NoUserCredentialsError => ex
      UI.error("An error occurred while verifying your certificates and profiles with the Apple Developer Portal.")
      UI.error("If you already have your certificates stored in git, you can run `fastlane match` in readonly mode")
      UI.error("to just install the certificates and profiles without accessing the Dev Portal.")
      UI.error("To do so, just pass `readonly: true` to your match call.")
      raise ex
    ensure
      storage.clear_changes if storage
    end
    # rubocop:enable Metrics/PerceivedComplexity

    # Syncs only the APNs authentication key, without any certificate or profile
    def run_push_auth_key(params)
      self.files_to_commit = []
      self.files_to_delete = []

      FileUtils.mkdir_p(params[:output_path]) if params[:output_path]

      FastlaneCore::PrintTable.print_values(config: params,
                                             title: "Summary for match #{Fastlane::VERSION}")

      prepare_storage(params)

      unless params[:readonly]
        self.spaceship = SpaceshipEnsure.new(params[:username], params[:team_id], params[:team_name], api_token(params))
      end

      fetch_push_auth_key(params)
    ensure
      storage.clear_changes if storage
    end

    # Downloads the storage and decrypts it
    def prepare_storage(params)
      update_optional_values_depending_on_storage_type(params)

      # Choose the right storage and encryption implementations
      storage_params = params
      storage_params[:username] = params[:readonly] ? nil : params[:username] # only pass username if not readonly
      self.storage = Storage.from_params(storage_params)
      storage.download

      # Init the encryption only after the `storage.download` was called to have the right working directory
      self.encryption = Encryption.for_storage_mode(params[:storage_mode], {
        git_url: params[:git_url],
        s3_bucket: params[:s3_bucket],
        s3_skip_encryption: params[:s3_skip_encryption],
        working_directory: storage.working_directory,
        force_legacy_encryption: params[:force_legacy_encryption]
      })
      self.encryption.decrypt_files if self.encryption
    end

    def api_token(params)
      api_token = Spaceship::ConnectAPI::Token.from(hash: params[:api_key], filepath: params[:api_key_path])
      return api_token
    end

    # Used when creating a new certificate or profile
    def prefixed_working_directory
      return self.storage.prefixed_working_directory
    end

    # Be smart about optional values here
    # Depending on the storage mode, different values are required
    def update_optional_values_depending_on_storage_type(params)
      if params[:storage_mode] != "git"
        params.option_for_key(:git_url).optional = true
      end
    end

    RENEWABLE_CERT_TYPES_VIA_API = [:mac_installer_distribution, :development, :distribution, :enterprise]

    def fetch_certificate(params: nil, renew_expired_certs: false, specific_cert_type: nil)
      cert_type = Match.cert_type_sym(specific_cert_type || params[:type])
      certificate_id = specific_cert_type.nil? ? params[:certificate_id] : nil

      certs = Dir[File.join(prefixed_working_directory, "certs", cert_type.to_s, "*.cer")]
      keys = Dir[File.join(prefixed_working_directory, "certs", cert_type.to_s, "*.p12")]

      storage_has_certs = certs.count != 0 && keys.count != 0

      # Determine if cert is renewable.
      # Can't renew developer_id certs with Connect API token. Account holder access is required.
      is_authenticated_with_login = Spaceship::ConnectAPI.token.nil?
      is_cert_renewable_via_api = RENEWABLE_CERT_TYPES_VIA_API.include?(cert_type)
      is_cert_renewable = is_authenticated_with_login || is_cert_renewable_via_api

      # Validate existing certificate first.
      # NOTE: only a single certificate is considered here — the one matching
      # `certificate_id`, or otherwise the last one found for this type.
      if renew_expired_certs && is_cert_renewable && storage_has_certs && !params[:readonly]
        cert_path = select_cert_or_key(paths: certs, certificate_id: certificate_id)

        unless Utils.is_cert_valid?(cert_path)
          UI.important("Removing invalid certificate '#{File.basename(cert_path)}'")

          # Remove expired cert.
          self.files_to_delete << cert_path
          File.delete(cert_path)

          # Key filename is the same as cert but with .p12 extension.
          key_path = cert_path.gsub(/\.cer$/, ".p12")
          # Remove expired key .p12 file.
          if File.exist?(key_path)
            self.files_to_delete << key_path
            File.delete(key_path)
          end

          certs = []
          keys = []
          storage_has_certs = false
        end
      end

      if !storage_has_certs
        UI.important("Couldn't find a valid code signing identity for #{cert_type}... creating one for you now")
        UI.crash!("No code signing identity found and cannot create a new one because you enabled `readonly`") if params[:readonly]
        cert_path = Generator.generate_certificate(params, cert_type, prefixed_working_directory, specific_cert_type: specific_cert_type)
        private_key_path = cert_path.gsub(".cer", ".p12")

        self.files_to_commit << cert_path
        self.files_to_commit << private_key_path

        # We pause to upload certs immediatly (or renewals) in case later logic fails, leaving
        # AppStore with a set of files de-synced from match storage. See fastlane/fastlane#30140
        save_changes_immediately!(params)

        # Reset certificates cache since we have a new cert.
        self.cache.reset_certificates
      else
        cert_path = select_cert_or_key(paths: certs, certificate_id: certificate_id)

        # Check validity of certificate
        if Utils.is_cert_valid?(cert_path)
          UI.verbose("Your certificate '#{File.basename(cert_path)}' is valid")
        else
          UI.user_error!("Your certificate '#{File.basename(cert_path)}' is not valid, please check end date and renew it if necessary")
        end

        if Helper.mac?
          UI.message("Installing certificate...")

          # Only looking for cert in "custom" (non login.keychain) keychain
          # Doing this for backwards compatibility
          keychain_name = params[:keychain_name] == "login.keychain" ? nil : params[:keychain_name]

          if FastlaneCore::CertChecker.installed?(cert_path, in_keychain: keychain_name)
            UI.verbose("Certificate '#{File.basename(cert_path)}' is already installed on this machine")
          else
            Utils.import(cert_path, params[:keychain_name], password: params[:keychain_password])

            # Import the private key
            # there seems to be no good way to check if it's already installed - so just install it
            # Key will only be added to the partition list if it isn't already installed
            Utils.import(select_cert_or_key(paths: keys, certificate_id: certificate_id), params[:keychain_name], password: params[:keychain_password])
          end
        else
          UI.message("Skipping installation of certificate as it would not work on this operating system.")
        end

        if params[:output_path]
          FileUtils.cp(cert_path, params[:output_path])
          FileUtils.cp(select_cert_or_key(paths: keys, certificate_id: certificate_id), params[:output_path])
        end

        # Get and print info of certificate
        info = Utils.get_cert_info(cert_path)
        TablePrinter.print_certificate_info(cert_info: info)
      end

      return File.basename(cert_path).gsub(".cer", "") # Certificate ID
    end

    # Makes sure the APNs authentication key (.p8) of the team is in storage,
    # creating it via pem if needed, and copies it to the output path
    #
    # @return (PEM::KeyManager::Result) the path to the copied .p8, the key ID and the team ID
    def fetch_push_auth_key(params)
      require 'pem/key_manager'
      require 'pem/options'

      key_dir = File.join(prefixed_working_directory, "keys", "apns")
      key_path = select_push_auth_key(key_dir, params[:push_auth_key_id])
      has_portal_session = !params[:readonly] && !Spaceship::Portal.client.nil?

      if key_path
        verify_push_auth_key_exists!(key_path) if has_portal_session
        UI.success("Using the APNs authentication key '#{push_auth_key_id(key_path)}' from your storage")
        team_id = spaceship.team_id if spaceship
      else
        UI.important("Couldn't find an APNs authentication key in your storage... getting one for you now")
        UI.user_error!("No APNs authentication key found and cannot create a new one because you enabled `readonly`") if params[:readonly]
        unless has_portal_session
          UI.user_error!([
            "Creating an APNs authentication key requires Apple ID login, not supported with App Store Connect API key authentication.",
            "Pass `username` to sign in with your Apple ID, or import an existing .p8 with `fastlane match import_push_auth_key`."
          ].join("\n"))
        end

        created = create_push_auth_key(params, key_dir)
        key_path = created.path
        team_id = created.team_id
        self.files_to_commit << key_path
      end

      output_path = File.expand_path(params[:output_path] || ".")
      exported_path = File.join(output_path, File.basename(key_path))
      FileUtils.mkdir_p(output_path)
      FileUtils.cp(key_path, exported_path)
      File.chmod(0o600, exported_path)
      UI.message("APNs authentication key: ".green + exported_path)

      unless self.files_to_commit.empty?
        begin
          save_changes_immediately!(params)
        rescue
          UI.error("Saving the new APNs authentication key to your storage failed. Apple only hands out the .p8 once, so keep #{exported_path}")
          UI.error("and add it with `fastlane match import_push_auth_key --push_auth_key_path #{exported_path}` once your storage works again.")
          raise
        end
      end

      self.push_auth_key = PEM::KeyManager::Result.new(exported_path, push_auth_key_id(key_path), team_id || params[:team_id])
    end

    # @return [String, nil] the .p8 in storage to use, if there is one
    def select_push_auth_key(key_dir, key_id)
      paths = Dir[File.join(key_dir, "AuthKey_*.p8")]
      paths = paths.select { |path| push_auth_key_id(path) == key_id } unless key_id.to_s.empty?

      if paths.count > 1
        ids = paths.map { |path| push_auth_key_id(path) }
        UI.user_error!("Found #{paths.count} APNs authentication keys in your storage (#{ids.join(', ')}). Pass `push_auth_key_id` to say which one to use.")
      end

      paths.first
    end

    def push_auth_key_id(path)
      File.basename(path, ".p8").delete_prefix("AuthKey_")
    end

    # A key that is no longer on the team can't send pushes anymore. It isn't removed
    # automatically: a run signed in to the wrong team would otherwise delete a key
    # that Apple will never hand out again.
    def verify_push_auth_key_exists!(key_path)
      key_id = push_auth_key_id(key_path)
      return if Spaceship.key.all.any? { |key| key.id == key_id }

      UI.user_error!([
        "The APNs authentication key '#{key_id}' in your storage doesn't exist on your team anymore.",
        "If it was revoked, remove #{File.join('keys', 'apns', File.basename(key_path))} from your storage and run match again to create a new one."
      ].join("\n"))
    end

    def create_push_auth_key(params, key_dir)
      PEM.config = FastlaneCore::Configuration.create(PEM::Options.key_options, {
        key_name: params[:push_auth_key_name],
        key_id: params[:push_auth_key_id],
        team_id: spaceship.team_id,
        output_path: key_dir
      }.compact)

      lost_p8_advice = lambda do |key_id|
        [
          "  - import the existing AuthKey_#{key_id}.p8 with `fastlane match import_push_auth_key --push_auth_key_path <path>`",
          "  - pass `push_auth_key_id` to use a different key",
          "  - run `fastlane pem revoke_auth_key --key_id #{key_id}` and run match again to create a new one"
        ]
      end

      PEM::KeyManager.create(login: false, lost_p8_advice: lost_p8_advice)
    end

    # Saves all pending file changes to storage right away, keeping the
    # working directory around so the current run can continue using it
    def save_changes_immediately!(params)
      return if params[:readonly]
      return if self.files_to_commit.empty? && self.files_to_delete.empty?

      self.encryption.encrypt_files if self.encryption
      begin
        self.storage.save_changes!(files_to_commit: self.files_to_commit,
                                   files_to_delete: self.files_to_delete,
                                   clear_working_directory: false)
      ensure
        # Always hand back a decrypted working directory, 2nd upload will hopefully work.
        self.encryption.decrypt_files if self.encryption
      end

      # We may have another upload at end (profiles) so reset our cert file(s).
      self.files_to_commit = []
      self.files_to_delete = []
    end

    # @return [String] Path to certificate or P12 key
    def select_cert_or_key(paths:, certificate_id: nil)
      return paths.last if certificate_id.to_s.strip.empty?

      cert_id_path = paths.find { |path| File.basename(path, File.extname(path)) == certificate_id }
      return cert_id_path if cert_id_path

      UI.user_error!("No certificate or key found for certificate_id '#{certificate_id}'")
    end

    # rubocop:disable Metrics/PerceivedComplexity
    # @return [String] The UUID of the provisioning profile so we can verify it with the Apple Developer Portal
    def fetch_provisioning_profile(params: nil, profile_type:, certificate_id: nil, app_identifier: nil, working_directory: nil)
      prov_type = Match.profile_type_sym(params[:type])

      names = [Match::Generator.profile_type_name(prov_type), app_identifier]
      if params[:platform].to_s == :tvos.to_s || params[:platform].to_s == :catalyst.to_s
        names.push(params[:platform])
      end

      profile_name = names.join("_").gsub("*", '\*') # this is important, as it shouldn't be a wildcard
      base_dir = File.join(prefixed_working_directory, "profiles", prov_type.to_s)

      extension = ".mobileprovision"
      if [:macos.to_s, :catalyst.to_s].include?(params[:platform].to_s)
        extension = ".provisionprofile"
      end

      profile_file = "#{profile_name}#{extension}"
      profiles = Dir[File.join(base_dir, profile_file)]
      if Helper.mac?
        keychain_path = FastlaneCore::Helper.keychain_path(params[:keychain_name]) unless params[:keychain_name].nil?
      end

      # Install the provisioning profiles
      stored_profile_path = profiles.last
      force = params[:force]

      if spaceship
        # check if profile needs to be updated only if not in readonly mode
        portal_profile = self.cache.portal_profile(stored_profile_path: stored_profile_path, keychain_path: keychain_path) if stored_profile_path

        if params[:force_for_new_devices]
          force ||= ProfileIncludes.should_force_include_all_devices?(params: params, portal_profile: portal_profile, cached_devices: self.cache.devices)
        end

        if params[:include_all_certificates]
          # Clearing specified certificate id which will prevent a profile being created with only one certificate
          certificate_id = nil
          force ||= ProfileIncludes.should_force_include_all_certificates?(params: params, portal_profile: portal_profile, cached_certificates: self.cache.certificates)
        end
      end

      is_new_profile_created = false
      if stored_profile_path.nil? || force
        if params[:readonly]
          UI.error("No matching provisioning profiles found for '#{profile_file}'")
          UI.error("A new one cannot be created because you enabled `readonly`")
          if Dir.exist?(base_dir) # folder for `prov_type` does not exist on first match use for that type
            all_profiles = Dir.entries(base_dir).reject { |f| f.start_with?(".") }
            UI.error("Provisioning profiles in your repo for type `#{prov_type}`:")
            all_profiles.each { |p| UI.error("- '#{p}'") }
          end
          UI.error("If you are certain that a profile should exist, double-check the recent changes to your match repository")
          UI.user_error!("No matching provisioning profiles found and cannot create a new one because you enabled `readonly`. Check the output above for more information.")
        end

        stored_profile_path = Generator.generate_provisioning_profile(
          params: params,
          prov_type: prov_type,
          certificate_id: certificate_id,
          app_identifier: app_identifier,
          force: force,
          cache: self.cache,
          working_directory: prefixed_working_directory
        )

        # Recreation of the profile means old profile is invalid.
        # Removing it from cache. We don't need a new profile in cache.
        self.cache.forget_portal_profile(portal_profile) if portal_profile

        self.files_to_commit << stored_profile_path

        is_new_profile_created = true
      end

      parsed = FastlaneCore::ProvisioningProfile.parse(stored_profile_path, keychain_path)
      uuid = parsed["UUID"]
      name = parsed["Name"]

      check_profile_existence = !is_new_profile_created && spaceship
      if check_profile_existence && !spaceship.profile_exists(profile_type: profile_type,
                                                              name: name,
                                                              username: params[:username],
                                                              uuid: uuid,
                                                              cached_profiles: self.cache.profiles)

        # This profile is invalid, let's remove the local file and generate a new one
        File.delete(stored_profile_path)
        # This method will be called again, no need to modify `files_to_commit`
        return nil
      end

      if Helper.mac?
        installed_profile = FastlaneCore::ProvisioningProfile.install(stored_profile_path, keychain_path)
      end

      if params[:output_path]
        FileUtils.cp(stored_profile_path, params[:output_path])
      end

      Utils.fill_environment(Utils.environment_variable_name(app_identifier: app_identifier,
                                                                       type: prov_type,
                                                                   platform: params[:platform]),

                             uuid)

      # TeamIdentifier is returned as an array, but we're not sure why there could be more than one
      Utils.fill_environment(Utils.environment_variable_name_team_id(app_identifier: app_identifier,
                                                                               type: prov_type,
                                                                           platform: params[:platform]),
                             parsed["TeamIdentifier"].first)

      cert_info = Utils.get_cert_info(parsed["DeveloperCertificates"].first.string).to_h
      Utils.fill_environment(Utils.environment_variable_name_certificate_name(app_identifier: app_identifier,
                                                                                        type: prov_type,
                                                                                    platform: params[:platform]),
                             cert_info["Common Name"])

      Utils.fill_environment(Utils.environment_variable_name_profile_name(app_identifier: app_identifier,
                                                                                    type: prov_type,
                                                                                platform: params[:platform]),
                             parsed["Name"])

      Utils.fill_environment(Utils.environment_variable_name_profile_path(app_identifier: app_identifier,
                                                                                    type: prov_type,
                                                                                platform: params[:platform]),
                             installed_profile)

      return uuid
    end
    # rubocop:enable Metrics/PerceivedComplexity
  end
  # rubocop:enable Metrics/ClassLength
end
