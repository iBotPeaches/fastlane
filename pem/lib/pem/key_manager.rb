require 'terminal-table'

require 'spaceship'
require 'fastlane_core/print_table'
require_relative 'manager'
require_relative 'module'

module PEM
  # Creates and manages APNs authentication keys (.p8)
  #
  # Unlike a push certificate, an authentication key never expires, covers the
  # sandbox and the production environment at once and is scoped to the whole
  # team instead of a single bundle identifier.
  #
  # Apple only hands out the .p8 of a key once, so everything in here is built
  # around never creating a key whose private key we then fail to store.
  class KeyManager
    Result = Struct.new(:path, :key_id, :team_id)

    class << self
      # Makes sure an APNs authentication key exists and that its .p8 is on disk
      #
      # @return (Result) the path to the .p8, the key ID and the team ID
      def create
        FastlaneCore::PrintTable.print_values(config: PEM.config, title: "Summary for PEM #{Fastlane::VERSION}")

        # Do this before talking to Apple: a key we can't store is a key that is lost
        ensure_output_path!
        PEM::Manager.login

        key = find_existing_key
        return use_existing_key(key) if key

        create_new_key
      end

      # Prints every authentication key of the team
      #
      # @return (Array) the keys of the team
      def list
        PEM::Manager.login

        keys = Spaceship.key.all
        if keys.empty?
          UI.important("Your team doesn't have any authentication keys yet.")
          return keys
        end

        # Apple only tells us how many services a key has, so each key has to be
        # fetched again to find out whether APNs is one of them
        UI.message("Fetching the services of #{keys.count} #{keys.count == 1 ? 'key' : 'keys'}...")
        rows = keys.map do |key|
          [key.id, key.name, bool(key.has_apns?), bool(key.can_download), bool(key.can_revoke)]
        end

        puts(Terminal::Table.new(title: "Authentication keys".green,
                                 headings: ["Key ID", "Name", "APNs", "Downloadable", "Revocable"],
                                 rows: rows))

        keys
      end

      # Revokes the authentication key passed as `key_id`
      #
      # @return (Boolean) whether the key was revoked
      def revoke
        PEM::Manager.login

        key_id = PEM.config[:key_id].to_s
        if key_id.empty?
          UI.user_error!("You need to pass the ID of the key to revoke, e.g. `fastlane pem revoke_auth_key --key_id ABCD123456`")
        end

        key = find_key(key_id)
        UI.user_error!("Couldn't find an authentication key with the ID '#{key_id}' on your team") if key.nil?

        unless PEM.config[:skip_confirmation]
          unless UI.interactive?
            UI.user_error!("Revoking '#{key.id}' needs to be confirmed, pass --skip_confirmation to revoke it without being asked")
          end

          message = "Revoke the authentication key '#{label(key)}' (#{key.id})? " \
                    "Every app and every server still using it will stop being able to send push notifications."
          return false unless UI.confirm(message)
        end

        key.revoke!
        UI.success("Revoked the authentication key '#{label(key)}' (#{key.id})")

        path = p8_path(key.id)
        UI.important("The file #{path} no longer works. You can delete it.") if File.exist?(path)

        true
      end

      private

      # Apple hands out the .p8 of a key exactly once, so make sure we are able to
      # store it before anything is created on their side
      def ensure_output_path!
        FileUtils.mkdir_p(output_path)
        unless File.writable?(output_path)
          UI.user_error!("Can't write to '#{output_path}'. An authentication key can only be downloaded once, so pem checks the output path before creating one.")
        end
      rescue SystemCallError => ex
        UI.user_error!("Can't use '#{output_path}' as the output path: #{ex.message}")
      end

      # The key this run should use, or nil if a new one has to be created
      def find_existing_key
        key_id = PEM.config[:key_id].to_s
        unless key_id.empty?
          UI.message("Looking up the authentication key '#{key_id}'...")
          key = find_key(key_id)
          UI.user_error!("Couldn't find an authentication key with the ID '#{key_id}' on your team") if key.nil?
          UI.user_error!("The authentication key '#{key_id}' is not enabled for APNs") unless key.has_apns?
          return key
        end

        if PEM.config[:force]
          UI.important("Creating a new authentication key, even if one already exists, since the --force option has been set.")
          return nil
        end

        name = PEM.config[:key_name]
        UI.message("Looking for an existing APNs authentication key named '#{name}'...")

        # `has_apns?` fetches the key again, so only ask for the ones matching by name
        matches = Spaceship.key.all.select { |key| key.name == name }.select(&:has_apns?)
        if matches.count > 1
          UI.user_error!("Found #{matches.count} APNs authentication keys named '#{name}' (#{matches.map(&:id).join(', ')}). Pass --key_id to say which one to use.")
        end

        matches.first
      end

      def use_existing_key(key)
        path = p8_path(key.id)

        if File.exist?(path)
          UI.success("The authentication key '#{label(key)}' (#{key.id}) was already downloaded. No need to create a new one.")
          return report(key, path)
        end

        if key.can_download
          UI.important("Downloading the authentication key '#{label(key)}' (#{key.id}). Apple only hands out the .p8 once, so store it somewhere safe.")
          return report(key, write_p8(key))
        end

        UI.user_error!([
          "The authentication key '#{label(key)}' (#{key.id}) exists, but Apple only lets you download a .p8 once and it has already been downloaded.",
          "There is no way to download it again. You can either:",
          "  - place the existing AuthKey_#{key.id}.p8 in #{output_path}",
          "  - pass --key_id to use a different key",
          "  - run `fastlane pem revoke_auth_key --key_id #{key.id}` and create a new one",
          "  - run `fastlane pem auth_key --force` to create an additional key, if your team is still below Apple's limit"
        ].join("\n"))
      end

      def create_new_key
        name = PEM.config[:key_name]
        UI.important("Creating a new APNs authentication key named '#{name}'.")

        key = Spaceship.key.create(name: name, apns: true)

        UI.important("Apple only hands out the .p8 once. Store it somewhere safe, it cannot be downloaded again.")
        report(key, write_p8(key))
      end

      def write_p8(key)
        content = key.download

        # `download_key` hands back the response body as is, so a key we can't use
        # has to be caught here rather than written to disk as if it worked
        unless content.kind_of?(String) && content.include?("PRIVATE KEY")
          UI.user_error!([
            "Apple didn't return a usable .p8 for the authentication key '#{label(key)}' (#{key.id}).",
            "The key exists, but its .p8 is lost: revoke it with `fastlane pem revoke_auth_key --key_id #{key.id}` and run pem again."
          ].join("\n"))
        end

        path = p8_path(key.id)
        # create the file private rather than fixing up the mode after writing a secret
        File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(content) }
        File.chmod(0o600, path)
        path
      end

      def report(key, path)
        absolute_path = File.expand_path(path)
        team_id = Spaceship.client.team_id

        UI.message("Key ID: ".green + key.id)
        UI.message("Team ID: ".green + team_id.to_s)
        UI.message("APNs authentication key: ".green + absolute_path)

        Result.new(absolute_path, key.id, team_id)
      end

      # `Key.find` builds a model out of the first entry of the response, so a key
      # that doesn't exist comes back without an ID, or blows up in the attribute
      # mapping because there is no entry at all
      def find_key(key_id)
        key = Spaceship.key.find(key_id)
        key if key && key.id
      rescue NoMethodError, Spaceship::Client::UnexpectedResponse => ex
        UI.verbose("Looking up the key '#{key_id}' failed: #{ex}")
        nil
      end

      # A freshly created key doesn't always come back with its name
      def label(key)
        key.name || PEM.config[:key_name]
      end

      def p8_path(key_id)
        File.join(output_path, "AuthKey_#{key_id}.p8")
      end

      def output_path
        File.expand_path(PEM.config[:output_path])
      end

      def bool(value)
        value ? "Yes" : "No"
      end
    end
  end
end
