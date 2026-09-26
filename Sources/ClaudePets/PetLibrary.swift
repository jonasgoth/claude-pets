import AppKit
import SpriteKit
import ImageIO

/// The Clawd pets: pre-baked frame sheets in Resources/pets (see tools/render-pets.py), one per
/// crab state. Frames are sliced from the sheet once and shared by every crab. Each crab's project
/// colour is applied on the GPU by `hueShader`, so there is one texture per state, not one per colour.
enum PetLibrary {
    struct Sheet {
        let file: String
        let frames: Int
        /// Points this pet hovers above the floor, and how far it drifts to each side.
        /// Zero for every pet that stands on the ground (see HOVER in tools/render-pets.py).
        let lift: CGFloat
        let sway: CGFloat
    }

    static let baseHueDegrees: CGFloat = 14     // the pets' own orange

    private static var cell: CGFloat = 240
    private static var cols = 8
    private static var rows = 4
    private(set) static var fps: Double = 8
    private static var sheets: [String: Sheet] = [:]
    /// The "working:<pet>" keys to draw from — one working animation per session.
    private static var workingKeys: [String] = []
    /// Which working animation each session drew, remembered on disk so a crab keeps its own
    /// personality across restarts.
    private static let workingPickDefaultsKey = "workingPetBySession"
    private static var workingPicks: [String: String] =
        (UserDefaults.standard.dictionary(forKey: "workingPetBySession") as? [String: String]) ?? [:]
    /// Animations spoken for by the crabs on screen right now, so a new crab never twins with a
    /// crab you can actually see while a free animation is left. Rebuilt as crabs claim their
    /// animation; `releaseWorkingKey` hands one back when a crab leaves.
    private static var liveWorkingKeys: [String: String] = [:]
    /// Beyond this many remembered sessions the picks are trimmed back to the live crabs, so an
    /// old stack of dead sessions can never skew the draw.
    private static let workingPickMemoryLimit = 200
    private static var frameCache: [String: [SKTexture]] = [:]
    /// One decoded sheet per file, so the plain and shadowless slicings share a single decode.
    private static var sheetTextures: [String: SKTexture] = [:]
    private static var loaded = false

    /// The pets are drawn standing on a flat drop shadow. Carried through the air that shadow
    /// reads as a dark bar floating under the crab, so a carried pet plays frames cropped to just
    /// above it. Measured off the sheets: the shadow (its soft top edge included) fills the bottom
    /// 27 of the cell's 240 px, and the legs stop right above that.
    static let shadowBand: CGFloat = 27.0 / 240.0

    static var directory: URL? { Bundle.main.resourceURL?.appendingPathComponent("pets") }

    /// True once the manifest and sheets are found in the app bundle.
    static var isAvailable: Bool { load(); return !sheets.isEmpty }

    private static let debug = ProcessInfo.processInfo.environment["CLAUDE_PETS_DEBUG"] == "1"

    private static func load() {
        guard !loaded else { return }
        loaded = true
        guard let dir = directory,
              let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let states = obj["states"] as? [String: [String: Any]] else {
            if debug { FileHandle.standardError.write(Data("[pets] no manifest at \(directory?.path ?? "nil")\n".utf8)) }
            return
        }
        if debug { FileHandle.standardError.write(Data("[pets] \(states.count) states from \(dir.path)\n".utf8)) }
        workingKeys = (obj["workingVariants"] as? [String]) ?? []
        cell = CGFloat((obj["cell"] as? Double) ?? 240)
        cols = (obj["cols"] as? Int) ?? 8
        rows = (obj["rows"] as? Int) ?? 4
        fps = (obj["fps"] as? Double) ?? 8
        for (state, info) in states {
            guard let file = info["file"] as? String, let frames = info["frames"] as? Int else { continue }
            sheets[state] = Sheet(file: file, frames: frames,
                                  lift: CGFloat((info["lift"] as? Double) ?? 0),
                                  sway: CGFloat((info["sway"] as? Double) ?? 0))
        }
    }

    /// The working animation this session keeps: drawn the first time the session is seen, then
    /// remembered, so every crab has its own working personality and keeps it across restarts.
    /// The draw skips whatever the crabs already on screen are playing, so no two visible crabs
    /// are twins while a free animation is left — and a remembered pick that would collide with a
    /// live crab is re-drawn rather than doubled up.
    static func workingKey(for id: String) -> String {
        load()
        guard !workingKeys.isEmpty else { return "working" }
        if let claimed = liveWorkingKeys[id] { return claimed }

        let taken = Set(liveWorkingKeys.filter { $0.key != id }.values)
        var picked = workingPicks[id]
        if let p = picked, !workingKeys.contains(p) || taken.contains(p) { picked = nil }
        let key = picked ?? draw(avoiding: taken)

        liveWorkingKeys[id] = key
        workingPicks[id] = key
        trimWorkingPicks()
        UserDefaults.standard.set(workingPicks, forKey: workingPickDefaultsKey)
        if debug { FileHandle.standardError.write(Data("[pets] \(id) -> \(key)\n".utf8)) }
        return key
    }

    /// A crab left the floor: its animation is free again for whoever arrives next. The pick stays
    /// remembered, so the same session coming back keeps its personality when it can.
    static func releaseWorkingKey(for id: String) {
        liveWorkingKeys[id] = nil
    }

    /// Pick an animation nobody on screen is playing, favouring the one fewest sessions have ever
    /// taken. With more crabs than animations the free pool runs dry, and the least-doubled-up
    /// animation wins instead.
    private static func draw(avoiding taken: Set<String>) -> String {
        let free = workingKeys.filter { !taken.contains($0) }
        var counts: [String: Int] = [:]
        if free.isEmpty {
            for key in liveWorkingKeys.values { counts[key, default: 0] += 1 }
        } else {
            for key in workingPicks.values { counts[key, default: 0] += 1 }
        }
        let pool = free.isEmpty ? workingKeys : free
        let fewest = pool.map { counts[$0] ?? 0 }.min() ?? 0
        let candidates = pool.filter { (counts[$0] ?? 0) == fewest }
        return candidates.randomElement() ?? pool[0]
    }

    /// Sessions are never seen again once they are gone, so the remembered picks would grow for
    /// ever and, worse, bias the draw toward whatever old sessions happened to miss.
    private static func trimWorkingPicks() {
        guard workingPicks.count > workingPickMemoryLimit else { return }
        workingPicks = workingPicks.filter { liveWorkingKeys[$0.key] != nil }
    }

    /// How far off the floor a pose plays: the flying pets (astronaut, flying, rocket) hover, and
    /// two of them also drift side to side. Everything else stands flat on the ground.
    static func hover(_ state: String) -> (lift: CGFloat, sway: CGFloat) {
        load()
        guard let sheet = sheets[state] else { return (0, 0) }
        return (sheet.lift, sheet.sway)
    }

    /// Animation frames for a state key ("working", "moving", …), shared by every crab.
    /// `withoutShadow` slices each cell to stop just above the baked-in ground shadow, for a crab
    /// held in the air. Empty if the state is unknown.
    static func frames(_ state: String, withoutShadow: Bool = false) -> [SKTexture] {
        load()
        let cacheKey = withoutShadow ? state + "#noshadow" : state
        if let cached = frameCache[cacheKey] { return cached }
        guard let sheet = sheets[state], let texture = sheetTexture(for: sheet) else { return [] }

        let crop = withoutShadow ? shadowBand : 0
        let w = 1.0 / CGFloat(cols), h = 1.0 / CGFloat(rows)
        var out: [SKTexture] = []
        for i in 0..<sheet.frames {
            let col = i % cols, row = i / cols
            // SpriteKit texture rects have their origin at the bottom-left, so cropping the
            // shadow off the foot of the cell means starting higher and keeping less.
            let rect = CGRect(x: CGFloat(col) * w, y: 1 - CGFloat(row + 1) * h + crop * h,
                              width: w, height: h * (1 - crop))
            let t = SKTexture(rect: rect, in: texture)
            t.filteringMode = .linear
            out.append(t)
        }
        frameCache[cacheKey] = out
        return out
    }

    private static func sheetTexture(for sheet: Sheet) -> SKTexture? {
        if let cached = sheetTextures[sheet.file] { return cached }
        guard let image = sourceImage(for: sheet) else { return nil }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .linear
        sheetTextures[sheet.file] = texture
        return texture
    }

    private static func sourceImage(for sheet: Sheet) -> CGImage? {
        guard let dir = directory,
              let source = CGImageSourceCreateWithURL(dir.appendingPathComponent(sheet.file) as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    // MARK: - Colour

    /// Per-sprite attribute: this crab's hue rotation in radians, away from the pets' own orange.
    static let hueAttribute = "a_hue"

    /// How much extra saturation the shell gets. Small on purpose: it should read a little richer,
    /// not turn into a traffic cone.
    static let vibrance: Float = 0.18

    /// What counts as shell, measured off the baked sheets: the body is drawn at hue 14 with a
    /// saturation of 0.51, while every prop is either far away in hue (the green check at 120, the
    /// blue screen at 199) or much more saturated (fire and flames at 0.7-0.8). So the shell is the
    /// band that is *both* near the base hue and no more saturated than the body, and only that band
    /// is recoloured. Each pair is the soft edge of one test: full effect at the first number,
    /// nothing past the second.
    static let shellHueWindow: (CGFloat, CGFloat) = (26, 42)        // degrees away from base hue
    static let shellSatWindow: (CGFloat, CGFloat) = (0.56, 0.66)    // HSV saturation

    /// Rotates the shell pixels' hue by the sprite's `a_hue` and gives them a small saturation lift,
    /// leaving props, eyes and highlights exactly as drawn. The texture is premultiplied, so the
    /// colour is un-premultiplied, worked on, and premultiplied again.
    static let hueShader: SKShader = {
        let shader = SKShader(source: """
        void main() {
            vec4 c = texture2D(u_texture, v_tex_coord);
            if (c.a > 0.001) {
                vec3 rgb = c.rgb / c.a;

                // How much this pixel is shell: near the base hue, and no more saturated than the body.
                float hi = max(rgb.r, max(rgb.g, rgb.b));
                float lo = min(rgb.r, min(rgb.g, rgb.b));
                float chroma = hi - lo;
                float sat = hi > 0.0001 ? chroma / hi : 0.0;
                float hue = 0.0;
                if (chroma > 0.0001) {
                    if (hi == rgb.r)      hue = 60.0 * mod((rgb.g - rgb.b) / chroma, 6.0);
                    else if (hi == rgb.g) hue = 60.0 * ((rgb.b - rgb.r) / chroma + 2.0);
                    else                  hue = 60.0 * ((rgb.r - rgb.g) / chroma + 4.0);
                }
                float dh = abs(hue - u_shell_hue);
                dh = min(dh, 360.0 - dh);
                float shell = (1.0 - smoothstep(u_hue_in, u_hue_out, dh))
                            * (1.0 - smoothstep(u_sat_in, u_sat_out, sat));

                if (shell > 0.001) {
                    vec3 tinted = rgb;
                    if (abs(a_hue) > 0.001) {
                        vec3 k = vec3(0.57735026919);
                        float cs = cos(a_hue);
                        float sn = sin(a_hue);
                        tinted = rgb * cs + cross(k, rgb) * sn + k * dot(k, rgb) * (1.0 - cs);
                    }
                    // Already-vivid pixels have less headroom, so they move least and nothing blows out.
                    float headroom = 1.0 - (max(tinted.r, max(tinted.g, tinted.b))
                                          - min(tinted.r, min(tinted.g, tinted.b)));
                    float lum = dot(tinted, vec3(0.2126, 0.7152, 0.0722));
                    tinted = mix(vec3(lum), tinted, 1.0 + u_vibrance * headroom);
                    rgb = mix(rgb, tinted, shell);
                }
                c.rgb = clamp(rgb, 0.0, 1.0) * c.a;
            }
            gl_FragColor = c * v_color_mix.a;
        }
        """)
        shader.uniforms = [
            SKUniform(name: "u_vibrance", float: vibrance),
            SKUniform(name: "u_shell_hue", float: Float(baseHueDegrees)),
            SKUniform(name: "u_hue_in", float: Float(shellHueWindow.0)),
            SKUniform(name: "u_hue_out", float: Float(shellHueWindow.1)),
            SKUniform(name: "u_sat_in", float: Float(shellSatWindow.0)),
            SKUniform(name: "u_sat_out", float: Float(shellSatWindow.1)),
        ]
        shader.attributes = [SKAttribute(name: hueAttribute, type: .float)]
        return shader
    }()

    static func hueValue(degrees: CGFloat) -> SKAttributeValue {
        SKAttributeValue(float: Float((degrees - baseHueDegrees) * .pi / 180))
    }
}
