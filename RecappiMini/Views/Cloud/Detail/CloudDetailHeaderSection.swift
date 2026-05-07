import SwiftUI

struct CloudDetailHeaderSection<Header: View, LatestJob: View, NewerVersion: View, Navigation: View>: View {
    private let header: Header
    private let latestJob: LatestJob
    private let newerVersion: NewerVersion
    private let navigation: Navigation

    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder latestJob: () -> LatestJob,
        @ViewBuilder newerVersion: () -> NewerVersion,
        @ViewBuilder navigation: () -> Navigation
    ) {
        self.header = header()
        self.latestJob = latestJob()
        self.newerVersion = newerVersion()
        self.navigation = navigation()
    }

    var body: some View {
        // peng-xiao `04644a8a` flagged the detail pane top whitespace
        // as wasteful. Keep the condensed header chrome centralized so
        // CloudRecordingDetail can compose sections without owning the
        // padding/spacing trivia inline.
        VStack(alignment: .leading, spacing: 9) {
            header
            // Failed/processing transcription banner (orange) sits above
            // the newer-version banner (blue) so terminal errors stay
            // closer to the header than informational refresh prompts.
            latestJob
            newerVersion
            navigation
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
}
