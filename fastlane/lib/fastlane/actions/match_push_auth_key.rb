module Fastlane
  module Actions
    module SharedValues
      MATCH_AUTH_KEY_PATH ||= :MATCH_AUTH_KEY_PATH # originally defined in SyncCodeSigningAction
      MATCH_AUTH_KEY_ID ||= :MATCH_AUTH_KEY_ID # originally defined in SyncCodeSigningAction
      MATCH_AUTH_KEY_TEAM_ID ||= :MATCH_AUTH_KEY_TEAM_ID # originally defined in SyncCodeSigningAction
    end

    class MatchPushAuthKeyAction < Action
      def self.run(params)
        require 'match'

        params.load_configuration_file("Matchfile")

        # Only set :api_key from SharedValues if :api_key_path isn't set (conflicting options)
        unless params[:api_key_path]
          params[:api_key] ||= Actions.lane_context[SharedValues::APP_STORE_CONNECT_API_KEY]
        end

        runner = Match::Runner.new
        runner.run_push_auth_key(params)

        SyncCodeSigningAction.define_push_auth_key(runner.push_auth_key)
        runner.push_auth_key.path
      end

      #####################################################
      # @!group Documentation
      #####################################################

      def self.description
        "Sync the APNs authentication key (.p8) of your team (via _match_)"
      end

      def self.details
        [
          "Keeps the APNs authentication key (.p8) of your team in your encrypted match storage, the same way _match_ keeps your certificates.",
          "When the storage has no key yet, one is looked up by name or created on the Developer Portal via _pem_ and saved to the storage right away, since Apple only hands out the .p8 once.",
          "Creating a key requires Apple ID login: App Store Connect API keys can't manage APNs authentication keys. Use `readonly: true` to only fetch the key from storage.",
          "To add a key you already have, run `fastlane match import_push_auth_key`.",
          "More information: https://docs.fastlane.tools/actions/match/"
        ].join("\n")
      end

      def self.available_options
        require 'match'
        Match::Options.available_options
      end

      def self.output
        [
          ['MATCH_AUTH_KEY_PATH', 'The path to the .p8 authentication key, copied to `output_path`'],
          ['MATCH_AUTH_KEY_ID', 'The ID of the authentication key'],
          ['MATCH_AUTH_KEY_TEAM_ID', 'The ID of the Developer Portal team the key belongs to']
        ]
      end

      def self.return_value
        "The absolute path to the .p8 authentication key"
      end

      def self.return_type
        :string
      end

      def self.authors
        ["iBotPeaches"]
      end

      def self.is_supported?(platform)
        [:ios, :mac].include?(platform)
      end

      def self.example_code
        [
          'match_push_auth_key',
          'match_push_auth_key(readonly: true, output_path: "./keys")',
          'match_push_auth_key(push_auth_key_id: "ABCD123456")'
        ]
      end

      def self.category
        :push
      end
    end
  end
end
