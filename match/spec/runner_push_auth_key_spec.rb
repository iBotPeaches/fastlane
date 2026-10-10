require 'pem/key_manager'

describe Match do
  describe Match::Runner do
    describe "#fetch_push_auth_key" do
      let(:runner) { Match::Runner.new }
      let(:p8) { "-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----\n" }
      let(:repo_dir) { Dir.mktmpdir }
      let(:output_dir) { Dir.mktmpdir }
      let(:key_dir) { File.join(repo_dir, "keys", "apns") }
      let(:key_class) { double("Spaceship::Portal::Key") }

      before do
        ENV.delete('FASTLANE_TEAM_ID')
        ENV.delete('FASTLANE_TEAM_NAME')

        runner.files_to_commit = []
        runner.files_to_delete = []
        allow(runner).to receive(:prefixed_working_directory).and_return(repo_dir)
        allow(Spaceship).to receive(:key).and_return(key_class)
        allow(Spaceship::Portal).to receive(:client).and_return(nil)
      end

      after do
        FileUtils.remove_entry(repo_dir)
        FileUtils.remove_entry(output_dir)
      end

      def config(values = {})
        FastlaneCore::Configuration.create(Match::Options.available_options, {
          git_url: "https://example.com",
          output_path: output_dir
        }.merge(values))
      end

      def store_key(key_id)
        FileUtils.mkdir_p(key_dir)
        path = File.join(key_dir, "AuthKey_#{key_id}.p8")
        File.write(path, p8)
        path
      end

      def sign_in(team_id: "ZZZTEAMID")
        allow(Spaceship::Portal).to receive(:client).and_return(double("portal client"))
        runner.spaceship = double("spaceship", team_id: team_id)
      end

      it "uses the key from storage in readonly mode without asking the Developer Portal" do
        store_key("ABCD123456")
        expect(key_class).to_not(receive(:all))
        expect(PEM::KeyManager).to_not(receive(:create))

        result = runner.fetch_push_auth_key(config(readonly: true))

        expect(result.path).to eq(File.join(output_dir, "AuthKey_ABCD123456.p8"))
        expect(result.key_id).to eq("ABCD123456")
        expect(File.read(result.path)).to eq(p8)
        expect(File.stat(result.path).mode & 0o777).to eq(0o600) unless FastlaneCore::Helper.windows? # NTFS has no POSIX mode bits
        expect(runner.files_to_commit).to be_empty
        expect(runner.push_auth_key).to eq(result)
      end

      it "checks that the stored key still exists on the team when signed in" do
        store_key("ABCD123456")
        sign_in
        expect(key_class).to receive(:all).and_return([double("key", id: "ABCD123456")])

        result = runner.fetch_push_auth_key(config)

        expect(result.team_id).to eq("ZZZTEAMID")
        expect(runner.files_to_commit).to be_empty
      end

      it "fails instead of deleting a stored key that no longer exists on the team" do
        path = store_key("ABCD123456")
        sign_in
        expect(key_class).to receive(:all).and_return([double("key", id: "OTHER12345")])

        expect do
          runner.fetch_push_auth_key(config)
        end.to raise_error(FastlaneCore::Interface::FastlaneError, /'ABCD123456' in your storage doesn't exist on your team anymore/)
        expect(File.exist?(path)).to be(true)
      end

      it "fails when the storage has no key in readonly mode" do
        expect(PEM::KeyManager).to_not(receive(:create))

        expect do
          runner.fetch_push_auth_key(config(readonly: true))
        end.to raise_error(FastlaneCore::Interface::FastlaneError, /cannot create a new one because you enabled `readonly`/)
      end

      it "fails when the storage has no key and there is no Apple ID session, e.g. with an API key" do
        runner.spaceship = double("spaceship", team_id: "ZZZTEAMID")
        expect(PEM::KeyManager).to_not(receive(:create))

        expect do
          runner.fetch_push_auth_key(config)
        end.to raise_error(FastlaneCore::Interface::FastlaneError, /requires Apple ID login/)
      end

      it "asks for push_auth_key_id when the storage has several keys" do
        store_key("ABCD123456")
        store_key("EFGH123456")

        expect do
          runner.fetch_push_auth_key(config(readonly: true))
        end.to raise_error(FastlaneCore::Interface::FastlaneError, /Found 2 APNs authentication keys .* Pass `push_auth_key_id`/)

        result = runner.fetch_push_auth_key(config(readonly: true, push_auth_key_id: "EFGH123456"))
        expect(result.key_id).to eq("EFGH123456")
      end

      describe "when the storage has no key" do
        let(:created_path) { File.join(key_dir, "AuthKey_NEWKEY1234.p8") }

        before do
          sign_in
          expect(PEM::KeyManager).to receive(:create).with(login: false, lost_p8_advice: kind_of(Proc)) do
            expect(PEM.config[:output_path]).to eq(key_dir)
            expect(PEM.config[:key_name]).to eq("fastlane APNs Key")
            expect(PEM.config[:team_id]).to eq("ZZZTEAMID")

            FileUtils.mkdir_p(key_dir)
            File.write(created_path, p8)
            PEM::KeyManager::Result.new(created_path, "NEWKEY1234", "ZZZTEAMID")
          end
        end

        it "gets one via pem and saves it to the storage right away" do
          expect(runner).to receive(:save_changes_immediately!) do
            expect(runner.files_to_commit).to eq([created_path])
          end

          result = runner.fetch_push_auth_key(config)

          expect(result.path).to eq(File.join(output_dir, "AuthKey_NEWKEY1234.p8"))
          expect(result.key_id).to eq("NEWKEY1234")
          expect(result.team_id).to eq("ZZZTEAMID")
          expect(File.read(result.path)).to eq(p8)
        end

        it "keeps the copied .p8 and says how to import it when saving to the storage fails" do
          expect(runner).to receive(:save_changes_immediately!).and_raise("push rejected")
          expect(FastlaneCore::UI).to receive(:error).with(/Saving the new APNs authentication key to your storage failed/)
          expect(FastlaneCore::UI).to receive(:error).with(/match import_push_auth_key --push_auth_key_path/)

          expect do
            runner.fetch_push_auth_key(config)
          end.to raise_error("push rejected")
          expect(File.read(File.join(output_dir, "AuthKey_NEWKEY1234.p8"))).to eq(p8)
        end
      end
    end

    describe "#run" do
      it "syncs the APNs authentication key before any certificate when push_auth_key is set" do
        runner = Match::Runner.new
        config = FastlaneCore::Configuration.create(Match::Options.available_options, {
          git_url: "https://example.com",
          app_identifier: "tools.fastlane.app",
          readonly: true,
          push_auth_key: true,
          skip_provisioning_profiles: true
        })

        expect(runner).to receive(:prepare_storage)
        expect(runner).to receive(:fetch_push_auth_key).ordered
        expect(runner).to receive(:fetch_certificate).ordered.and_return("CERTID")

        runner.run(config)
      end
    end

    describe "#run_push_auth_key" do
      it "only syncs the APNs authentication key" do
        runner = Match::Runner.new
        storage = double("storage", clear_changes: nil)
        config = FastlaneCore::Configuration.create(Match::Options.available_options, {
          git_url: "https://example.com",
          readonly: true
        })

        expect(runner).to receive(:prepare_storage) { runner.storage = storage }
        expect(runner).to receive(:fetch_push_auth_key).with(config)
        expect(runner).to_not(receive(:fetch_certificate))
        expect(Match::SpaceshipEnsure).to_not(receive(:new))
        expect(storage).to receive(:clear_changes)

        runner.run_push_auth_key(config)
      end
    end
  end
end
