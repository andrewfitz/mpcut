import AppKit
import MPCutCore
import SwiftUI

struct StillThumbnail: View {
    let frame: StillReviewFrame
    var maximumDimension: Int = 192

    private struct Request: Equatable {
        let identity: SourceIdentity
        let asset: StillAsset
        let framing: StillImageFraming
        let maximumDimension, width, height: Int
    }

    @State private var loaded: (request: Request, image: CGImage)?

    var body: some View {
        let request = Request(identity: frame.identity, asset: frame.asset, framing: frame.framing,
                              maximumDimension: maximumDimension, width: frame.width, height: frame.height)
        Color.black
            .overlay {
                if let loaded, loaded.request == request {
                    Image(decorative: loaded.image, scale: 1)
                        .resizable()
                        .scaledToFit()
                }
            }
            .task(id: request) {
                let image = await MulticamThumbnailWork.shared.run(url: frame.url) {
                    let render = Task.detached(priority: .utility) { [frame, maximumDimension] in
                        try frame.image(maximumDimension: maximumDimension, cancelled: { Task.isCancelled })
                    }
                    return await withTaskCancellationHandler {
                        try? await render.value
                    } onCancel: { render.cancel() }
                }
                guard let image, !Task.isCancelled else { return }
                loaded = (request, image)
            }
            .accessibilityHidden(true)
    }
}
