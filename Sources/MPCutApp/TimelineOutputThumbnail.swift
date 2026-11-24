import CoreGraphics
import Foundation
import MPCutCore
import SwiftUI

struct TimelineOutputRevision: Equatable, Sendable {
    let generation: UUID
    let edit: Int
    let document: URL?
    var media: UInt64 = 0
}

/// Owns the output decoder for one edit revision. Only the timeline's
/// in-memory tile cache stores the rendered pictures.
actor TimelineOutputThumbnailRenderer {
    private let project: CutProject
    private let document: URL
    private var picture: ParticipantOutputPicture?
    private var multicamIntervals: [MulticamInterval]?

    init(project: CutProject, document: URL?) {
        self.project = project
        self.document = document ?? LiveProjectMediaArchive.untitledURL
    }

    func image(at time: RationalTime, size: CGSize) throws -> CGImage {
        try Task.checkCancellation()
        if picture == nil {
            picture = try ParticipantOutputPicture(project: project, document: document, forceSDR: true,
                                                   cancelled: { Task.isCancelled })
        }
        guard let picture else { throw CancellationError() }
        let image = try picture.thumbnail(at: time, size: size)
        try Task.checkCancellation()
        return image
    }

    func image(group: RationalTime, recording: String, size: CGSize) throws -> CGImage? {
        try Task.checkCancellation()
        if multicamIntervals == nil, case .multicam(let multicam) = project {
            multicamIntervals = try multicam.plan().intervals
        }
        guard let interval = multicamIntervals?.first(where: {
            $0.pictureSourceID == recording && $0.group.contains(group)
        }) else { return nil }
        let time = try interval.output.from.adding(group.subtracting(interval.group.from))
        return try image(at: time, size: size)
    }
}

@MainActor
struct TimelineOutputThumbnail: View {
    let revision: TimelineOutputRevision
    let time: RationalTime
    let recording: String
    let size: CGSize
    let thumbnail: (RationalTime, String, CGSize) async -> CGImage?

    private struct Request: Equatable {
        let revision: TimelineOutputRevision
        let time: RationalTime
        let recording: String
        let size: CGSize
    }

    @State private var loaded: (Request, CGImage)?

    var body: some View {
        let request = Request(revision: revision, time: time, recording: recording, size: size)
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let (cached, image) = loaded, cached == request {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .clipped()
        }
        .task(id: request) {
            loaded = nil
            guard let image = await thumbnail(time, recording, size), !Task.isCancelled else { return }
            loaded = (request, image)
        }
        .accessibilityHidden(true)
    }
}
