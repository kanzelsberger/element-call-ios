//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// A timeline that drives the call layout without a backend: the rosters the core would publish,
/// stated directly, and the things a user does between them.
///
/// The grammar is platform-neutral and owned by feature-hq (`plans/003.call_layout/scenarios/`),
/// so Android can run the same files through its layout and the two dumps can be compared. A
/// scenario states the model's **output** — the order, with flags — never the events that produce
/// it: re-implementing the ranking here would be a second ranking free to drift from the core's.
///
/// One frame per line, `<time> <roster>` or `<time> <action> [arguments]`, times non-decreasing.
/// Blank lines and `//` comments are ignored. A roster is remote tiles in rank order, highest
/// first, our own tile implicit; a token is a name (uppercase letters and digits), an optional `#`
/// for that member's screen share, and flags: `*` hero, `!` speaking, `^` hand raised, `v` has
/// video, `m` microphone muted.
@available(iOS 18, *)
public nonisolated struct MatrixRTCScenario: Sendable, Equatable {
    /// One remote tile as a scenario names it. `A` and `A#` are two tiles of one member.
    public struct Token: Sendable, Hashable {
        public let name: String
        public let kind: MatrixRTCTileKind
        public var isHero = false
        public var isSpeaking = false
        public var hasHandRaised = false
        public var hasVideo = false
        public var isMicrophoneMuted = false
        
        public init(name: String, kind: MatrixRTCTileKind = .person, isHero: Bool = false, isSpeaking: Bool = false, hasHandRaised: Bool = false, hasVideo: Bool = false, isMicrophoneMuted: Bool = false) {
            self.name = name
            self.kind = kind
            self.isHero = isHero
            self.isSpeaking = isSpeaking
            self.hasHandRaised = hasHandRaised
            self.hasVideo = hasVideo
            self.isMicrophoneMuted = isMicrophoneMuted
        }
        
        /// The same people as the preview fixtures, so a scenario and a snapshot describe one call.
        public var memberID: String {
            "@\(name):example.com:DEVICE"
        }
        
        public var userID: String {
            "@\(name.lowercased()):example.com"
        }
        
        public var tileID: MatrixRTCTileID {
            MatrixRTCTileID(memberID: memberID, kind: kind)
        }
    }
    
    public enum Orientation: Sendable, Equatable {
        case portrait, landscape
    }
    
    public enum HeroDirection: Sendable, Equatable {
        case next, previous
    }
    
    public enum Event: Sendable, Equatable {
        /// The order the core publishes, with detail for every tile unless narrowed by `detailOnly`.
        case roster([Token])
        /// The stage's size in points and its safe-area insets.
        case viewport(size: CGSize, topInset: CGFloat, bottomInset: CGFloat)
        /// The scroll offset in points, clamped as a user's scroll would be.
        case scroll(CGFloat)
        case rotate(Orientation)
        /// Double-tap a tile into fullscreen, or `nil` back out.
        case fullscreen(MatrixRTCTileID?)
        case swipeHero(HeroDirection)
        /// The stage unmounts (Picture in Picture or the bar) and comes back.
        case minimize
        case restore
        /// Our own camera and microphone.
        case me(hasVideo: Bool, isMicrophoneMuted: Bool)
        /// The next rosters carry detail only for these tiles; everything else is a reference.
        case detailOnly([MatrixRTCTileID])
        /// No change; forces a dump at this time, to observe something on the call's own clock.
        case tick
    }
    
    public struct Frame: Sendable, Equatable {
        public let time: Duration
        public let event: Event
        /// One-based, for a dump header and for an error.
        public let line: Int
        /// The line as written, comment stripped, for the dump header.
        public let text: String
    }
    
    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public let scenario: String
        public let line: Int
        public let message: String
        
        public init(scenario: String, line: Int, message: String) {
            self.scenario = scenario
            self.line = line
            self.message = message
        }
        
        public var description: String {
            "\(scenario):\(line): \(message)"
        }
    }
    
    /// The stage a scenario runs on unless it says otherwise: an iPhone in portrait, 34 pt of home
    /// indicator, the same numbers the layout tests use.
    public static let defaultViewport = Event.viewport(size: CGSize(width: 393, height: 734), topInset: 0, bottomInset: 34)
    
    public let name: String
    public let frames: [Frame]
    
    public init(name: String, frames: [Frame]) {
        self.name = name
        self.frames = frames
    }
    
    // MARK: - Parsing
    
    private static let actions: Set = ["viewport", "scroll", "rotate", "fullscreen", "swipe-hero", "minimize", "restore", "me", "detail-only", "tick"]
    
    public static func parse(_ text: String, name: String) throws -> MatrixRTCScenario {
        var frames = [Frame]()
        var previous = Duration.zero
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let number = index + 1
            let line = rawLine.components(separatedBy: "//").first?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty else { continue }
            func fail(_ message: String) -> ParseError {
                ParseError(scenario: name, line: number, message: message)
            }
            var words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let time = parseTime(words.removeFirst()) else {
                throw fail("a frame starts with a time such as `2s` or `250ms`")
            }
            guard time >= previous else {
                throw fail("times must not decrease")
            }
            previous = time
            let event: Event
            if let first = words.first, actions.contains(first) {
                event = try parseAction(first, arguments: Array(words.dropFirst()), fail: fail)
            } else {
                event = try .roster(words.map { try parseToken($0, fail: fail) })
            }
            frames.append(Frame(time: time, event: event, line: number, text: line))
        }
        return MatrixRTCScenario(name: name, frames: frames)
    }
    
    private static func parseTime(_ word: String) -> Duration? {
        if word.hasSuffix("ms"), let value = Double(word.dropLast(2)) {
            return .milliseconds(value)
        }
        if word.hasSuffix("s"), let value = Double(word.dropLast(1)) {
            return .seconds(value)
        }
        return nil
    }
    
    private static func parseToken(_ word: String, fail: (String) -> ParseError) throws -> Token {
        var rest = Substring(word)
        // Uppercase, digits and underscores only: two of the flags (`v`, `m`) are letters, so a
        // name that could contain lowercase would swallow them and `Cv` would be a member called
        // Cv with no video. The corpus writes `A`, `B`, `M001`; the README says so.
        let name = rest.prefix { $0.isUppercase || $0.isNumber || $0 == "_" }
        guard !name.isEmpty else {
            throw fail("`\(word)` does not start with a member name (uppercase letters and digits)")
        }
        rest = rest.dropFirst(name.count)
        var token = Token(name: String(name))
        if rest.first == "#" {
            token = Token(name: String(name), kind: .screenShare)
            rest = rest.dropFirst()
        }
        for flag in rest {
            switch flag {
            case "*": token.isHero = true
            case "!": token.isSpeaking = true
            case "^": token.hasHandRaised = true
            case "v": token.hasVideo = true
            case "m": token.isMicrophoneMuted = true
            default: throw fail("`\(flag)` in `\(word)` is not a flag (* ! ^ v m)")
            }
        }
        return token
    }
    
    private static func parseAction(_ action: String, arguments: [String], fail: (String) -> ParseError) throws -> Event {
        switch action {
        case "viewport":
            guard let size = arguments.first, let (width, height) = parseSize(size) else {
                throw fail("viewport needs a size such as `393x734`")
            }
            var top: CGFloat = 0, bottom: CGFloat = 0
            var rest = arguments.dropFirst()
            while let edge = rest.first {
                rest = rest.dropFirst()
                guard let value = rest.first.flatMap({ Double($0) }) else {
                    throw fail("`\(edge)` needs a number of points after it")
                }
                rest = rest.dropFirst()
                switch edge {
                case "top": top = value
                case "bottom": bottom = value
                default: throw fail("`\(edge)` is not an inset (top, bottom)")
                }
            }
            return .viewport(size: CGSize(width: width, height: height), topInset: top, bottomInset: bottom)
        case "scroll":
            guard let offset = arguments.first.flatMap({ Double($0) }) else {
                throw fail("scroll needs an offset in points")
            }
            return .scroll(offset)
        case "rotate":
            switch arguments.first {
            case "portrait": return .rotate(.portrait)
            case "landscape": return .rotate(.landscape)
            default: throw fail("rotate needs `portrait` or `landscape`")
            }
        case "fullscreen":
            guard let target = arguments.first else {
                throw fail("fullscreen needs a token or `none`")
            }
            return try .fullscreen(target == "none" ? nil : parseToken(target, fail: fail).tileID)
        case "swipe-hero":
            switch arguments.first {
            case "next": return .swipeHero(.next)
            case "previous": return .swipeHero(.previous)
            default: throw fail("swipe-hero needs `next` or `previous`")
            }
        case "minimize":
            return .minimize
        case "restore":
            return .restore
        case "me":
            let flags = arguments.first ?? ""
            for flag in flags where flag != "v" && flag != "m" {
                throw fail("`\(flag)` is not a flag for me (v m)")
            }
            return .me(hasVideo: flags.contains("v"), isMicrophoneMuted: flags.contains("m"))
        case "detail-only":
            return try .detailOnly(arguments.map { try parseToken($0, fail: fail).tileID })
        case "tick":
            return .tick
        default:
            throw fail("`\(action)` is not an action")
        }
    }
    
    private static func parseSize(_ word: String) -> (CGFloat, CGFloat)? {
        let parts = word.split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else { return nil }
        return (CGFloat(width), CGFloat(height))
    }
}
