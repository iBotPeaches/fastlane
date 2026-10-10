require 'tmpdir'

describe PEM do
  describe PEM::KeyManager do
    let(:key_class) { double("Spaceship::Portal::Key") }
    let(:p8) { "-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----\n" }

    before do
      ENV["DELIVER_USER"] = "test@fastlane.tools"
      ENV["DELIVER_PASSWORD"] = "123"

      pem_stub_spaceship_login
      allow(Spaceship).to receive(:key).and_return(key_class)
    end

    def configure(options = {})
      PEM.config = FastlaneCore::Configuration.create(PEM::Options.key_options, options)
    end

    describe "create" do
      it "creates a new key and writes the p8 when the team has none" do
        Dir.mktmpdir do |dir|
          key = pem_stub_key(can_download: true)
          expect(key_class).to receive(:all).and_return([])
          expect(key_class).to receive(:create).with(name: "fastlane APNs Key", apns: true).and_return(key)
          expect(key).to receive(:download).and_return(p8)

          configure(output_path: dir)
          result = PEM::KeyManager.create

          expect(result.path).to eq(File.join(dir, "AuthKey_ABCD123456.p8"))
          expect(result.key_id).to eq("ABCD123456")
          expect(result.team_id).to eq("ZZZTEAMID")
          path = result.path
          expect(File.read(path)).to eq(p8)
          expect(File.stat(path).mode & 0o777).to eq(0o600) unless FastlaneCore::Helper.windows? # NTFS has no POSIX mode bits
        end
      end

      it "reuses the p8 that is already on disk instead of creating a new key" do
        Dir.mktmpdir do |dir|
          key = pem_stub_key
          expect(key_class).to receive(:all).and_return([key])
          expect(key_class).to_not(receive(:create))

          existing_path = File.join(dir, "AuthKey_ABCD123456.p8")
          File.write(existing_path, p8)

          configure(output_path: dir)
          expect(PEM::KeyManager.create.path).to eq(existing_path)
          expect(File.read(existing_path)).to eq(p8)
        end
      end

      it "downloads an existing key that has never been downloaded" do
        Dir.mktmpdir do |dir|
          key = pem_stub_key(can_download: true)
          expect(key_class).to receive(:all).and_return([key])
          expect(key_class).to_not(receive(:create))
          expect(key).to receive(:download).and_return(p8)

          configure(output_path: dir)
          expect(PEM::KeyManager.create.path).to eq(File.join(dir, "AuthKey_ABCD123456.p8"))
        end
      end

      it "fails instead of silently creating a second key when the p8 can't be downloaded again" do
        Dir.mktmpdir do |dir|
          key = pem_stub_key(can_download: false)
          expect(key_class).to receive(:all).and_return([key])
          expect(key_class).to_not(receive(:create))

          configure(output_path: dir)
          expect do
            PEM::KeyManager.create
          end.to raise_error(FastlaneCore::Interface::FastlaneError, /only lets you download a .p8 once/)
        end
      end

      it "ignores the existing key when force is set" do
        Dir.mktmpdir do |dir|
          created = pem_stub_key(id: "NEWKEY1234")
          expect(key_class).to_not(receive(:all))
          expect(key_class).to receive(:create).with(name: "fastlane APNs Key", apns: true).and_return(created)
          expect(created).to receive(:download).and_return(p8)

          configure(output_path: dir, force: true)
          expect(PEM::KeyManager.create.path).to eq(File.join(dir, "AuthKey_NEWKEY1234.p8"))
        end
      end

      it "looks up a key by its ID when key_id is given" do
        Dir.mktmpdir do |dir|
          key = pem_stub_key(id: "GIVENID123", can_download: true)
          expect(key_class).to receive(:find).with("GIVENID123").and_return(key)
          expect(key_class).to_not(receive(:all))
          expect(key).to receive(:download).and_return(p8)

          configure(output_path: dir, key_id: "GIVENID123")
          expect(PEM::KeyManager.create.path).to eq(File.join(dir, "AuthKey_GIVENID123.p8"))
        end
      end

      it "fails when the given key_id isn't an APNs key" do
        Dir.mktmpdir do |dir|
          expect(key_class).to receive(:find).with("GIVENID123").and_return(pem_stub_key(id: "GIVENID123", apns: false))

          configure(output_path: dir, key_id: "GIVENID123")
          expect do
            PEM::KeyManager.create
          end.to raise_error(FastlaneCore::Interface::FastlaneError, /not enabled for APNs/)
        end
      end

      it "skips keys of the team that don't match the configured name" do
        Dir.mktmpdir do |dir|
          other = pem_stub_key(id: "OTHERKEY12", name: "Somebody else's key")
          created = pem_stub_key(id: "MINE123456", name: "My key")
          expect(key_class).to receive(:all).and_return([other])
          expect(key_class).to receive(:create).with(name: "My key", apns: true).and_return(created)
          expect(created).to receive(:download).and_return(p8)

          configure(output_path: dir, key_name: "My key")
          expect(PEM::KeyManager.create.path).to eq(File.join(dir, "AuthKey_MINE123456.p8"))
        end
      end

      it "fails before creating anything when the output path can't be written to" do
        Dir.mktmpdir do |dir|
          read_only = File.join(dir, "read_only")
          FileUtils.mkdir_p(read_only)
          File.chmod(0555, read_only)

          expect(Spaceship).to_not(receive(:login))
          expect(key_class).to_not(receive(:all))
          expect(key_class).to_not(receive(:create))

          configure(output_path: read_only)
          expect do
            PEM::KeyManager.create
          end.to raise_error(FastlaneCore::Interface::FastlaneError, /Can't write to/)
        end
      end

      it "fails without writing a file when Apple doesn't return a usable .p8" do
        Dir.mktmpdir do |dir|
          key = pem_stub_key(can_download: true)
          expect(key_class).to receive(:all).and_return([key])
          expect(key).to receive(:download).and_return({ "resultCode" => 1100 })

          configure(output_path: dir)
          expect do
            PEM::KeyManager.create
          end.to raise_error(FastlaneCore::Interface::FastlaneError, /didn't return a usable .p8/)

          expect(Dir.children(dir)).to eq([])
        end
      end

      it "refuses to guess when several keys share the configured name" do
        Dir.mktmpdir do |dir|
          keys = [pem_stub_key(id: "FIRSTKEY12"), pem_stub_key(id: "SECONDKEY1")]
          expect(key_class).to receive(:all).and_return(keys)
          expect(key_class).to_not(receive(:create))

          configure(output_path: dir)
          expect do
            PEM::KeyManager.create
          end.to raise_error(FastlaneCore::Interface::FastlaneError, /FIRSTKEY12, SECONDKEY1/)
        end
      end
    end

    describe "list" do
      it "returns the keys of the team" do
        keys = [pem_stub_key, pem_stub_key(id: "OTHERKEY12", name: "Other", apns: false)]
        expect(key_class).to receive(:all).and_return(keys)

        configure
        expect(PEM::KeyManager.list).to eq(keys)
      end

      it "handles a team without any key" do
        expect(key_class).to receive(:all).and_return([])

        configure
        expect(PEM::KeyManager.list).to eq([])
      end
    end

    describe "revoke" do
      it "revokes the key when force skips the confirmation" do
        key = pem_stub_key
        expect(key_class).to receive(:find).with("ABCD123456").and_return(key)
        expect(key).to receive(:revoke!)

        configure(key_id: "ABCD123456", skip_confirmation: true)
        expect(PEM::KeyManager.revoke).to eq(true)
      end

      it "asks for a confirmation and does nothing when it is declined" do
        key = pem_stub_key
        expect(key_class).to receive(:find).with("ABCD123456").and_return(key)
        expect(key).to_not(receive(:revoke!))
        allow(FastlaneCore::UI).to receive(:interactive?).and_return(true)
        expect(FastlaneCore::UI).to receive(:confirm).and_return(false)

        configure(key_id: "ABCD123456")
        expect(PEM::KeyManager.revoke).to eq(false)
      end

      it "fails instead of revoking without a confirmation when it can't ask" do
        key = pem_stub_key
        expect(key_class).to receive(:find).with("ABCD123456").and_return(key)
        expect(key).to_not(receive(:revoke!))
        allow(FastlaneCore::UI).to receive(:interactive?).and_return(false)

        configure(key_id: "ABCD123456")
        expect do
          PEM::KeyManager.revoke
        end.to raise_error(FastlaneCore::Interface::FastlaneError, /needs to be confirmed/)
      end

      it "fails when no key_id is given" do
        configure
        expect do
          PEM::KeyManager.revoke
        end.to raise_error(FastlaneCore::Interface::FastlaneError, /pass the ID of the key to revoke/)
      end

      it "fails when the key doesn't exist" do
        expect(key_class).to receive(:find).with("MISSING123").and_return(nil)

        configure(key_id: "MISSING123")
        expect do
          PEM::KeyManager.revoke
        end.to raise_error(FastlaneCore::Interface::FastlaneError, /Couldn't find an authentication key/)
      end
    end

    after do
      ENV.delete("DELIVER_USER")
      ENV.delete("DELIVER_PASSWORD")
    end
  end
end
