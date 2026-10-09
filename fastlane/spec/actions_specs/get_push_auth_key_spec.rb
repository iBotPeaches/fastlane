describe Fastlane do
  describe Fastlane::FastFile do
    describe "get_push_auth_key Integration" do
      it "works with no parameters" do
        result = Fastlane::FastFile.new.parse("lane :test do
          get_push_auth_key
        end").runner.execute(:test)

        expect(result).to start_with("/")
        expect(File.basename(result)).to eq("AuthKey_TEST12345.p8")
      end

      # the team_id option writes FASTLANE_TEAM_ID through its verify_block
      it "exposes the key, its path and the team in the lane context", env_output: %w[FASTLANE_TEAM_ID] do
        Fastlane::FastFile.new.parse("lane :test do
          get_push_auth_key(team_id: 'ZZZTEAMID')
        end").runner.execute(:test)

        lane_context = Fastlane::Actions.lane_context
        expect(File.basename(lane_context[Fastlane::Actions::SharedValues::PEM_AUTH_KEY_PATH])).to eq("AuthKey_TEST12345.p8")
        expect(lane_context[Fastlane::Actions::SharedValues::PEM_AUTH_KEY_ID]).to eq("TEST12345")
        expect(lane_context[Fastlane::Actions::SharedValues::PEM_AUTH_KEY_TEAM_ID]).to eq("ZZZTEAMID")
      end
    end
  end
end
