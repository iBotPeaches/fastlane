require 'match'

describe Fastlane do
  describe Fastlane::FastFile do
    describe "match_push_auth_key Integration" do
      it "exposes the key synced by match in the lane context" do
        runner = Match::Runner.new
        expect(Match::Runner).to receive(:new).and_return(runner)
        expect(runner).to receive(:run_push_auth_key) do |params|
          expect(params[:readonly]).to be(true)
          runner.push_auth_key = PEM::KeyManager::Result.new("/tmp/AuthKey_ABCD123456.p8", "ABCD123456", "ZZZTEAMID")
        end

        result = Fastlane::FastFile.new.parse("lane :test do
          match_push_auth_key(readonly: true, git_url: 'https://example.com')
        end").runner.execute(:test)

        expect(result).to eq("/tmp/AuthKey_ABCD123456.p8")
        lane_context = Fastlane::Actions.lane_context
        expect(lane_context[Fastlane::Actions::SharedValues::MATCH_AUTH_KEY_PATH]).to eq("/tmp/AuthKey_ABCD123456.p8")
        expect(lane_context[Fastlane::Actions::SharedValues::MATCH_AUTH_KEY_ID]).to eq("ABCD123456")
        expect(lane_context[Fastlane::Actions::SharedValues::MATCH_AUTH_KEY_TEAM_ID]).to eq("ZZZTEAMID")
      end
    end

    describe "sync_code_signing Integration" do
      it "exposes the APNs authentication key when push_auth_key is set" do
        runner = Match::Runner.new
        expect(Match::Runner).to receive(:new).and_return(runner)
        expect(runner).to receive(:run) do |params|
          expect(params[:push_auth_key]).to be(true)
          runner.push_auth_key = PEM::KeyManager::Result.new("/tmp/AuthKey_ABCD123456.p8", "ABCD123456", "ZZZTEAMID")
        end

        Fastlane::FastFile.new.parse("lane :test do
          sync_code_signing(readonly: true, push_auth_key: true, git_url: 'https://example.com', app_identifier: 'tools.fastlane.app')
        end").runner.execute(:test)

        expect(Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::MATCH_AUTH_KEY_ID]).to eq("ABCD123456")
      end
    end
  end
end
