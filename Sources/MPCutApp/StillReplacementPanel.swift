import AppKit
import MPCutCore

struct StillReplacementRequest {
    let replacement: StillReplacement
    let action: StillPlacementAction
    let clock: String?
    let fragmentIndex: Int?
    var from: RationalTime?
    var to: RationalTime?
    var at: RationalTime?

    var title: String {
        switch action {
        case .move: "Move Still"
        case .resize: "Trim Still"
        case .duplicate: "Duplicate Still"
        case .detach: "Detach Still Fragment"
        case .frame, .remove, .relink: "Edit Still"
        }
    }

    func apply(to project: CutProject,
               snap: (RationalTime, String?, StillReplacementFragment?) throws -> RationalTime) throws -> CutProject {
        let fragment: StillReplacementFragment?
        if let fragmentIndex {
            guard case .sequence(let fragments) = replacement.coverage,
                  fragments.indices.contains(fragmentIndex) else {
                throw CutError(code: "invalid_still", message: "The selected still fragment is unavailable.")
            }
            fragment = fragments[fragmentIndex]
        } else {
            fragment = nil
        }
        func boundary(_ time: RationalTime) throws -> RationalTime { try snap(time, clock, fragment) }
        return try project.editingStillReplacement(id: replacement.id, fragmentIndex: fragmentIndex,
                                                   from: from.map(boundary), to: to.map(boundary), at: at.map(boundary),
                                                   clock: clock, duplicateID: action == .duplicate ? UUID().uuidString : nil,
                                                   detachID: action == .detach ? UUID().uuidString : nil)
    }
}

@MainActor
extension StillPanels {
    static func editReplacement(_ replacement: StillReplacement, action: StillPlacementAction, in window: NSWindow?,
                                plan: StillTimelinePlan? = nil, completion: @escaping (StillReplacementRequest) -> Void) {
        switch replacement.coverage {
        case .group(let bounds):
            editReplacementBounds(replacement, action: action, clock: "group", bounds: bounds,
                                  fragmentIndex: nil, in: window, completion: completion)
        case .sequence(let fragments):
            if action != .detach,
               let spans = plan?.spans.filter({ $0.placementID == replacement.id }),
               let first = spans.first, let last = spans.last, spans.count == fragments.count,
               spans.allSatisfy({ span in
                   guard case .source(let clipID, let range) = span.origin else { return false }
                   return fragments.contains(.init(clipID: clipID, range: range))
               }) {
                editReplacementBounds(replacement, action: action, clock: "sequence",
                                      bounds: .init(from: first.output.from, to: last.output.to),
                                      fragmentIndex: nil, in: window, completion: completion)
                return
            }
            func editFragment(_ index: Int) {
                if action == .detach {
                    completion(.init(replacement: replacement, action: action, clock: nil, fragmentIndex: index))
                } else {
                    editReplacementBounds(replacement, action: action, clock: "source", bounds: fragments[index].range,
                                          fragmentIndex: index, in: window, completion: completion)
                }
            }
            if fragments.count == 1 { editFragment(0); return }
            let picker = NSPopUpButton()
            picker.toolTip = "Choose source fragment"
            picker.addItems(withTitles: fragments.enumerated().map { index, fragment in
                "\(index + 1) · \(fragment.range.from)–\(fragment.range.to) s · \(fragment.clipID)"
            })
            present(title: action == .detach ? "Detach Still Fragment" : "Choose Still Fragment",
                    fields: [("Source fragment", picker)], in: window) {
                guard fragments.indices.contains(picker.indexOfSelectedItem) else { return }
                editFragment(picker.indexOfSelectedItem)
            }
        }
    }

    private static func editReplacementBounds(_ replacement: StillReplacement, action: StillPlacementAction,
                                              clock: String, bounds: MulticamRange, fragmentIndex: Int?,
                                              in window: NSWindow?, completion: @escaping (StillReplacementRequest) -> Void) {
        let start = NSTextField(string: (action == .duplicate ? bounds.to : bounds.from).description)
        let end = NSTextField(string: bounds.to.description)
        start.toolTip = action == .resize ? "Set placement start" : "Set placement destination"
        end.toolTip = "Set placement end"
        var request = StillReplacementRequest(replacement: replacement, action: action, clock: clock,
                                              fragmentIndex: fragmentIndex)
        let label = clock.capitalized
        let fields: [(String, NSControl)] = action == .resize
            ? [("\(label) start (seconds)", start), ("\(label) end (seconds)", end)]
            : [("\(label) destination (seconds)", start)]
        present(title: request.title, fields: fields, in: window) {
            do {
                let first = try RationalTime(parsing: start.stringValue.trimmingCharacters(in: .whitespaces))
                if action == .resize {
                    let last = try RationalTime(parsing: end.stringValue.trimmingCharacters(in: .whitespaces))
                    if first != bounds.from { request.from = first }
                    if last != bounds.to { request.to = last }
                    guard request.from != nil || request.to != nil else { return }
                } else {
                    guard action == .duplicate || first != bounds.from else { return }
                    request.at = first
                }
                completion(request)
            } catch { ProjectPanels.present(NSAlert(error: error), in: window) }
        }
    }
}
