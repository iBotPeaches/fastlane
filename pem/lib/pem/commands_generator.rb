require 'commander'

require 'fastlane/version'
require 'fastlane_core/configuration/configuration'
require 'fastlane_core/ui/help_formatter'
require_relative 'options'
require_relative 'manager'
require_relative 'key_manager'

HighLine.track_eof = false

module PEM
  class CommandsGenerator
    include Commander::Methods

    def self.start
      self.new.run
    end

    def run
      program :name, 'pem'
      program :version, Fastlane::VERSION
      program :description, 'CLI for \'PEM\' - Automatically generate and renew your push notification profiles'
      program :help, 'Author', 'Felix Krause <pem@krausefx.com>'
      program :help, 'Website', 'https://fastlane.tools'
      program :help, 'Documentation', 'https://docs.fastlane.tools/actions/pem/'
      program :help_formatter, FastlaneCore::HelpFormatter

      global_option('--verbose') { FastlaneCore::Globals.verbose = true }
      global_option('--env STRING[,STRING2]', String, 'Add environment(s) to use with `dotenv`')

      command :renew do |c|
        c.syntax = 'fastlane pem renew'
        c.description = 'Renews the certificate (in case it expired) and shows the path to the generated pem file'

        FastlaneCore::CommanderGenerator.new.generate(PEM::Options.available_options, command: c)

        c.action do |args, options|
          PEM.config = FastlaneCore::Configuration.create(PEM::Options.available_options, options.__hash__)
          PEM::Manager.start
        end
      end

      command :auth_key do |c|
        c.syntax = 'fastlane pem auth_key'
        c.description = 'Creates an APNs authentication key (.p8) if needed and shows the path to it'

        FastlaneCore::CommanderGenerator.new.generate(PEM::Options.key_options, command: c)

        c.action do |args, options|
          PEM.config = FastlaneCore::Configuration.create(PEM::Options.key_options, options.__hash__)
          PEM::KeyManager.create
        end
      end

      command :list_auth_keys do |c|
        c.syntax = 'fastlane pem list_auth_keys'
        c.description = 'Lists the authentication keys of your Developer Portal team'

        FastlaneCore::CommanderGenerator.new.generate(PEM::Options.key_options, command: c)

        c.action do |args, options|
          PEM.config = FastlaneCore::Configuration.create(PEM::Options.key_options, options.__hash__)
          PEM::KeyManager.list
        end
      end

      command :revoke_auth_key do |c|
        c.syntax = 'fastlane pem revoke_auth_key'
        c.description = 'Revokes the authentication key with the given key ID'

        FastlaneCore::CommanderGenerator.new.generate(PEM::Options.key_options, command: c)

        c.action do |args, options|
          PEM.config = FastlaneCore::Configuration.create(PEM::Options.key_options, options.__hash__)
          PEM::KeyManager.revoke
        end
      end

      default_command(:renew)

      run!
    end
  end
end
