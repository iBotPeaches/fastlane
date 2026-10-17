require 'pem/commands_generator'

describe PEM::CommandsGenerator do
  let(:available_options) { PEM::Options.available_options }

  describe ":renew option handling" do
    it "can use the save_private_key short flag from tool options" do
      # leaving out the command name defaults to 'renew'
      stub_commander_runner_args(['-s', 'false'])

      expected_options = FastlaneCore::Configuration.create(available_options, { save_private_key: false })

      expect(PEM::Manager).to receive(:start)

      PEM::CommandsGenerator.start

      expect(PEM.config._values).to eq(expected_options._values)
    end

    it "can use the development flag from tool options" do
      # leaving out the command name defaults to 'renew'
      stub_commander_runner_args(['--development', 'true'])

      expected_options = FastlaneCore::Configuration.create(available_options, { development: true })

      expect(PEM::Manager).to receive(:start)

      PEM::CommandsGenerator.start

      expect(PEM.config._values).to eq(expected_options._values)
    end
  end

  describe "authentication key commands" do
    let(:key_options) { PEM::Options.key_options }

    it "runs the auth_key command" do
      stub_commander_runner_args(['auth_key', '--key_name', 'My key'])

      expected_options = FastlaneCore::Configuration.create(key_options, { key_name: 'My key' })

      expect(PEM::KeyManager).to receive(:create)

      PEM::CommandsGenerator.start

      expect(PEM.config._values).to eq(expected_options._values)
    end

    it "runs the list_auth_keys command" do
      stub_commander_runner_args(['list_auth_keys'])

      expect(PEM::KeyManager).to receive(:list)

      PEM::CommandsGenerator.start

      expect(PEM.config._values).to eq(FastlaneCore::Configuration.create(key_options, {})._values)
    end

    it "runs the revoke_auth_key command with the key_id short flag" do
      stub_commander_runner_args(['revoke_auth_key', '-i', 'ABCD123456', '--skip_confirmation', 'true'])

      expected_options = FastlaneCore::Configuration.create(key_options, { key_id: 'ABCD123456', skip_confirmation: true })

      expect(PEM::KeyManager).to receive(:revoke)

      PEM::CommandsGenerator.start

      expect(PEM.config._values).to eq(expected_options._values)
    end
  end
end
