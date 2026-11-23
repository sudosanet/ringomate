import simd

extension PropMesh {
    /// 画面は +Z。
    public static func phone() -> PropMesh {
        var m = PropMesh()
        let h = SIMD3<Float>(0.036, 0.072, 0.006)
        m.cuboid(.zero, h)
        m.material("case", SIMD3(1, 0.62, 0.78))
        m.quad(SIMD3(0, 0.004, h.z + 0.0005), SIMD3(1, 0, 0) * (h.x - 0.004), SIMD3(0, 1, 0) * (h.y - 0.01))
        m.material("screen", SIMD3(0.62, 0.86, 1))
        return m
    }

    /// ページは +Z、背は −Z 側。
    static func openBook() -> PropMesh {
        var m = PropMesh()
        let (w, h): (Float, Float) = (0.095, 0.14)
        let halves: [(Float, Float)] = [(-1, Math.radians(22)), (1, -Math.radians(22))]
        for (sx, a) in halves {
            let start = m.positions.count
            m.cuboid(SIMD3(sx * w / 2, 0, -0.002), SIMD3(w / 2, h / 2, 0.002))
            m.transform(from: start, rotation(y: a), .zero)
        }
        m.material("cover", SIMD3(0.72, 0.62, 0.95))
        for (sx, a) in halves {
            let start = m.positions.count
            m.cuboid(SIMD3(sx * (w / 2 - 0.004), 0, 0.006), SIMD3(w / 2 - 0.006, h / 2 - 0.005, 0.006))
            m.transform(from: start, rotation(y: a), .zero)
        }
        m.material("pages", SIMD3(1, 0.97, 0.88))
        m.cuboid(SIMD3(0, -h / 2 - 0.02, 0.008), SIMD3(0.004, 0.03, 0.0008))
        m.material("ribbon", SIMD3(1, 0.55, 0.72))
        return m
    }

    /// 前は +Z。
    static func pipeChair() -> PropMesh {
        var m = PropMesh()
        let leg: Float = 0.014
        for x: Float in [-0.19, 0.19] {
            m.cuboid(SIMD3(x, 0.21, 0.17), SIMD3(leg, 0.21, leg))
            m.cuboid(SIMD3(x, 0.42, -0.19), SIMD3(leg, 0.42, leg))
            m.cuboid(SIMD3(x, 0.1, -0.01), SIMD3(leg * 0.8, leg * 0.8, 0.18))
        }
        m.cuboid(SIMD3(0, 0.1, 0.17), SIMD3(0.19, leg * 0.8, leg * 0.8))
        m.material("frame", SIMD3(0.82, 0.84, 0.9))
        m.cuboid(SIMD3(0, 0.43, 0), SIMD3(0.21, 0.025, 0.2))
        m.cuboid(SIMD3(0, 0.74, -0.19), SIMD3(0.2, 0.08, 0.02))
        m.material("seat", SIMD3(0.62, 0.9, 0.84))
        return m
    }

    public static func mug() -> PropMesh {
        var m = PropMesh()
        m.cylinder(.zero, 0.04, 0.042, 0.09, 16)
        m.material("cup", SIMD3(1, 0.97, 0.95))
        m.cuboid(SIMD3(0.055, 0.045, 0), SIMD3(0.012, 0.025, 0.006))
        m.material("handle", SIMD3(1, 0.65, 0.78))
        m.cylinder(SIMD3(0, 0.085, 0), 0.037, 0.037, 0.003, 16)
        m.material("cocoa", SIMD3(0.55, 0.35, 0.25))
        return m
    }

    public static func bottle() -> PropMesh {
        var m = PropMesh()
        m.cylinder(.zero, 0.03, 0.03, 0.15, 14)
        m.cylinder(SIMD3(0, 0.15, 0), 0.03, 0.012, 0.04, 14)
        m.material("water", SIMD3(0.7, 0.9, 1))
        m.cylinder(SIMD3(0, 0.19, 0), 0.013, 0.013, 0.015, 12)
        m.material("cap", SIMD3(0.5, 0.88, 0.75))
        return m
    }

    public static func iceCream() -> PropMesh {
        var m = PropMesh()
        m.cylinder(.zero, 0.004, 0.035, 0.1, 14)
        m.material("cone", SIMD3(0.93, 0.75, 0.48))
        m.sphere(SIMD3(0, 0.11, 0), 0.04, SIMD3(1, 0.8, 1))
        m.cylinder(SIMD3(0, 0.13, 0), 0.03, 0, 0.05, 14)
        m.material("cream", SIMD3(1, 0.75, 0.85))
        return m
    }

    public static func onigiri() -> PropMesh {
        var m = PropMesh()
        m.cylinder(SIMD3(0, -0.04, 0), 0.05, 0.012, 0.08, 3)
        m.material("rice", SIMD3(1, 1, 0.98))
        m.cuboid(SIMD3(0, -0.025, 0.03), SIMD3(0.025, 0.02, 0.003))
        m.material("nori", SIMD3(0.15, 0.2, 0.18))
        return m
    }

    public static func lollipop() -> PropMesh {
        var m = PropMesh()
        m.cylinder(.zero, 0.004, 0.004, 0.12, 8)
        m.material("stick", SIMD3(1, 1, 1))
        let start = m.positions.count
        m.cylinder(.zero, 0.045, 0.045, 0.016, 20)
        m.transform(from: start, rotation(x: .pi / 2), SIMD3(0, 0.16, 0.008))
        m.material("candy", SIMD3(1, 0.55, 0.75))
        return m
    }

    public static func flower() -> PropMesh {
        var m = PropMesh()
        m.cylinder(.zero, 0.004, 0.004, 0.16, 8)
        m.cuboid(SIMD3(0.02, 0.07, 0), SIMD3(0.018, 0.006, 0.003))
        m.material("stem", SIMD3(0.45, 0.78, 0.45))
        for k in 0..<5 {
            let a = Float(k) / 5 * (2 * .pi)
            m.sphere(SIMD3(cos(a) * 0.025, 0.17 + sin(a) * 0.025, 0), 0.017, SIMD3(1, 1, 0.4))
        }
        m.material("petals", SIMD3(1, 0.62, 0.78))
        m.sphere(SIMD3(0, 0.17, 0.006), 0.013, SIMD3(1, 1, 0.6))
        m.material("center", SIMD3(1, 0.88, 0.35))
        return m
    }

    public static func balloon() -> PropMesh {
        var m = PropMesh()
        m.cylinder(.zero, 0.0015, 0.0015, 0.45, 6)
        m.material("string", SIMD3(0.95, 0.95, 0.95))
        m.sphere(SIMD3(0, 0.55, 0), 0.1, SIMD3(1, 1.15, 1))
        m.cylinder(SIMD3(0, 0.43, 0), 0.006, 0.014, 0.012, 8)
        m.material("balloon", SIMD3(0.6, 0.85, 1))
        return m
    }

    public static func umbrella() -> PropMesh {
        var m = PropMesh()
        m.cylinder(.zero, 0.006, 0.006, 0.6, 8)
        m.material("shaft", SIMD3(0.96, 0.96, 0.98))
        m.cylinder(SIMD3(0, 0.42, 0), 0.4, 0, 0.26, 8)
        m.cylinder(SIMD3(0, 0.4, 0), 0.4, 0.4, 0.02, 8)
        m.material("canopy", SIMD3(0.78, 0.68, 1))
        return m
    }

    public static func fan() -> PropMesh {
        var m = PropMesh()
        m.cuboid(SIMD3(0, 0.05, 0), SIMD3(0.007, 0.05, 0.004))
        m.material("grip", SIMD3(1, 1, 1))
        let start = m.positions.count
        m.cylinder(.zero, 0.08, 0.08, 0.004, 20)
        m.transform(from: start, rotation(x: .pi / 2), SIMD3(0, 0.17, 0.002))
        m.material("face", SIMD3(1, 0.7, 0.82))
        return m
    }

    public static func teddy() -> PropMesh {
        var m = PropMesh()
        m.sphere(SIMD3(0, -0.04, 0), 0.07, SIMD3(1, 1.1, 0.9))
        m.sphere(SIMD3(0, 0.08, 0.01), 0.06, SIMD3(1, 1, 1))
        for x: Float in [-0.045, 0.045] {
            m.sphere(SIMD3(x, 0.13, 0), 0.022, SIMD3(1, 1, 1))
            m.sphere(SIMD3(x * 1.4, -0.02, 0.03), 0.025, SIMD3(1, 1.4, 1))
            m.sphere(SIMD3(x * 0.9, -0.12, 0.03), 0.028, SIMD3(1, 1, 1))
        }
        m.material("fur", SIMD3(0.86, 0.7, 0.55))
        m.sphere(SIMD3(0, 0.065, 0.06), 0.022, SIMD3(1.2, 0.9, 0.8))
        m.material("muzzle", SIMD3(1, 0.96, 0.9))
        for x: Float in [-0.022, 0.022] { m.sphere(SIMD3(x, 0.095, 0.055), 0.007, SIMD3(1, 1, 1)) }
        m.sphere(SIMD3(0, 0.075, 0.08), 0.007, SIMD3(1, 1, 1))
        m.material("eyes", SIMD3(0.2, 0.15, 0.15))
        return m
    }

    public static func camera() -> PropMesh {
        var m = PropMesh()
        m.cuboid(.zero, SIMD3(0.06, 0.04, 0.025))
        m.material("body", SIMD3(0.98, 0.95, 0.92))
        let start = m.positions.count
        m.cylinder(.zero, 0.025, 0.022, 0.03, 16)
        m.transform(from: start, rotation(x: -.pi / 2), SIMD3(0, 0, -0.02))
        m.material("lens", SIMD3(0.55, 0.8, 0.95))
        return m
    }

    public static func controller() -> PropMesh {
        var m = PropMesh()
        m.cuboid(.zero, SIMD3(0.07, 0.012, 0.035))
        for x: Float in [-0.06, 0.06] { m.sphere(SIMD3(x, 0, 0.02), 0.03, SIMD3(1, 0.5, 1)) }
        m.material("body", SIMD3(0.6, 0.88, 0.8))
        for (x, z): (Float, Float) in [(0.035, -0.008), (0.05, 0.004), (0.035, 0.016), (0.02, 0.004)] {
            m.cylinder(SIMD3(x, 0.012, z), 0.006, 0.006, 0.005, 10)
        }
        m.cuboid(SIMD3(-0.035, 0.014, 0.004), SIMD3(0.016, 0.003, 0.005))
        m.cuboid(SIMD3(-0.035, 0.014, 0.004), SIMD3(0.005, 0.003, 0.016))
        m.material("buttons", SIMD3(1, 0.62, 0.75))
        return m
    }

    public static func magnifier() -> PropMesh {
        var m = PropMesh()
        m.cylinder(.zero, 0.009, 0.009, 0.1, 10)
        m.material("grip", SIMD3(0.7, 0.5, 0.35))
        var start = m.positions.count
        m.cylinder(.zero, 0.05, 0.05, 0.008, 20)
        m.transform(from: start, rotation(x: .pi / 2), SIMD3(0, 0.15, 0.004))
        m.material("rim", SIMD3(0.95, 0.8, 0.4))
        start = m.positions.count
        m.cylinder(.zero, 0.043, 0.043, 0.01, 20)
        m.transform(from: start, rotation(x: .pi / 2), SIMD3(0, 0.15, 0.005))
        m.material("glass", SIMD3(0.75, 0.92, 1))
        return m
    }

    /// 頭の中心が原点、耳は ±X、`width` はメートル。
    public static func headphones(_ width: Float) -> PropMesh {
        var m = PropMesh()
        let r = width / 2 + 0.012
        for k in 0..<9 {
            let a = Float(k) / 8 * .pi
            m.cuboid(SIMD3(cos(a) * r, sin(a) * r, 0), SIMD3(0.012, 0.012, 0.018))
        }
        m.material("band", SIMD3(1, 0.62, 0.78))
        for x in [-r, r] {
            let start = m.positions.count
            m.cylinder(.zero, 0.035, 0.035, 0.03, 16)
            m.transform(from: start, rotation(z: .pi / 2), SIMD3(x + (x < 0 ? -1 : 1) * 0.015, 0, 0))
        }
        m.material("pads", SIMD3(1, 0.98, 0.98))
        return m
    }

    public static func toothbrush() -> PropMesh {
        var m = PropMesh()
        m.cuboid(SIMD3(0, 0.08, 0), SIMD3(0.006, 0.08, 0.004))
        m.material("handle", SIMD3(0.55, 0.85, 1))
        m.cuboid(SIMD3(0, 0.15, 0.008), SIMD3(0.006, 0.012, 0.006))
        m.material("bristles", SIMD3(1, 1, 1))
        return m
    }

    public static func comb() -> PropMesh {
        var m = PropMesh()
        m.cuboid(SIMD3(0, 0.05, 0), SIMD3(0.006, 0.05, 0.003))
        m.cuboid(SIMD3(0.012, 0.13, 0), SIMD3(0.006, 0.04, 0.003))
        for k in 0..<8 { m.cuboid(SIMD3(0.024, 0.096 + Float(k) * 0.009, 0), SIMD3(0.008, 0.0015, 0.002)) }
        m.material("comb", SIMD3(0.8, 0.7, 1))
        return m
    }

    public static func paintbrush() -> PropMesh {
        var m = PropMesh()
        m.cylinder(.zero, 0.006, 0.005, 0.15, 8)
        m.material("handle", SIMD3(1, 0.85, 0.4))
        m.cylinder(SIMD3(0, 0.15, 0), 0.006, 0.006, 0.02, 8)
        m.material("ferrule", SIMD3(0.85, 0.86, 0.9))
        m.cylinder(SIMD3(0, 0.17, 0), 0.006, 0, 0.03, 8)
        m.material("tip", SIMD3(1, 0.55, 0.7))
        return m
    }
}
