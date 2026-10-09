module Fastlane
  module Actions
    module SharedValues
      PEM_AUTH_KEY_PATH = :PEM_AUTH_KEY_PATH
      PEM_AUTH_KEY_ID = :PEM_AUTH_KEY_ID
      PEM_AUTH_KEY_TEAM_ID = :PEM_AUTH_KEY_TEAM_ID
    end

    class GetPushAuthKeyAction < Action
      def self.run(params)
        require 'pem'
        require 'pem/options'
        require 'pem/key_manager'

        PEM.config = params

        if Helper.test?
          result = PEM::KeyManager::Result.new(File.expand_path('./AuthKey_TEST12345.p8'), 'TEST12345', params[:team_id])
        else
          result = PEM::KeyManager.create
        end

        return nil unless result

        Actions.lane_context[SharedValues::PEM_AUTH_KEY_PATH] = result.path
        Actions.lane_context[SharedValues::PEM_AUTH_KEY_ID] = result.key_id
        Actions.lane_context[SharedValues::PEM_AUTH_KEY_TEAM_ID] = result.team_id || params[:team_id]

        result.path
      end

      def self.description
        "Get an APNs authentication key (.p8), creating a new one if needed (via _pem_)"
      end

      def self.details
        [
          "An APNs authentication key is the token based alternative to a push certificate: it never expires, it covers the sandbox and the production environment at once and it is shared by every app of your team.",
          "Apple only lets you download the `.p8` of a key once. This action therefore reuses the file in `output_path` when it is already there, and refuses to silently create a second key when the existing one can no longer be downloaded.",
          "Authentication keys live on the Developer Portal, which has no App Store Connect API, so this action always signs in with your Apple ID. On CI you need a `FASTLANE_SESSION`."
        ].join("\n")
      end

      def self.available_options
        require 'pem'
        require 'pem/options'

        PEM::Options.key_options
      end

      def self.output
        [
          ['PEM_AUTH_KEY_PATH', 'The path to the .p8 authentication key'],
          ['PEM_AUTH_KEY_ID', 'The ID of the authentication key'],
          ['PEM_AUTH_KEY_TEAM_ID', 'The ID of the Developer Portal team the key belongs to']
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
          'get_push_auth_key',
          'get_push_auth_key(
            key_name: "Push notifications", # the name shown in the Developer Portal
            output_path: "./keys"           # where the .p8 is stored
          )',
          'get_push_auth_key(
            key_id: "ABCD123456" # download a specific existing key instead of looking one up by name
          )'
        ]
      end

      def self.category
        :push
      end
    end
  end
end
