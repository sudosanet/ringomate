import CMeshopt
import Foundation

enum GLTFExpand {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func split(_ glb: [UInt8]) throws -> ([String: Any], [UInt8]) {
        guard glb.count >= 20, glb[0..<4].elementsEqual("glTF".utf8) else { throw Failure(description: "not a GLB file") }
        let jsonLen = Int(le32(glb, 12))
        guard 20 + jsonLen <= glb.count else { throw Failure(description: "GLB JSON is truncated") }
        guard let json = try JSONSerialization.jsonObject(with: Data(glb[20..<20 + jsonLen])) as? [String: Any] else {
            throw Failure(description: "GLB JSON is not an object")
        }
        let at = 20 + jsonLen
        var bin: [UInt8] = []
        if glb.count >= at + 8 {
            let len = Int(le32(glb, at))
            guard at + 8 + len <= glb.count else { throw Failure(description: "GLB BIN is truncated") }
            bin = Array(glb[at + 8..<at + 8 + len])
        }
        return (json, bin)
    }

    static func join(_ json: [String: Any], _ bin: [UInt8]) throws -> [UInt8] {
        var j = [UInt8](try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes]))
        while j.count % 4 != 0 { j.append(UInt8(ascii: " ")) }
        var b = bin
        while b.count % 4 != 0 { b.append(0) }
        let total = 12 + 8 + j.count + (b.isEmpty ? 0 : 8 + b.count)
        var w = ByteWriter()
        w.out = Array("glTF".utf8)
        w.u32(2)
        w.u32(UInt32(total))
        w.u32(UInt32(j.count))
        w.out += Array("JSON".utf8) + j
        if !b.isEmpty {
            w.u32(UInt32(b.count))
            w.out += Array("BIN".utf8) + [0] + b
        }
        return w.out
    }

    static func pushView(_ json: inout [String: Any], _ bin: inout [UInt8], _ data: [UInt8]) -> Int {
        while bin.count % 4 != 0 { bin.append(0) }
        let offset = bin.count
        bin += data
        var views = json["bufferViews"] as? [Any] ?? []
        views.append(["buffer": 0, "byteOffset": offset, "byteLength": data.count])
        json["bufferViews"] = views
        return views.count - 1
    }

    static func pack(_ jsonBytes: [UInt8], read: (String) -> [UInt8]?) throws -> [UInt8] {
        guard var json = try JSONSerialization.jsonObject(with: Data(jsonBytes)) as? [String: Any] else {
            throw Failure(description: ".gltf JSON is not an object")
        }
        var bin: [UInt8] = []
        var base: [Int] = []
        for b in json["buffers"] as? [[String: Any]] ?? [] {
            while bin.count % 4 != 0 { bin.append(0) }
            base.append(bin.count)
            guard let uri = b["uri"] as? String else { throw Failure(description: "external buffer has no uri") }
            if uri.hasPrefix("data:") {
                guard let r = uri.range(of: ";base64,") else { throw Failure(description: "can't read data URI") }
                bin += base64(String(uri[r.upperBound...]))
            } else {
                guard let d = read(percentDecode(uri)) else { throw Failure(description: "\(uri) is missing") }
                bin += d
            }
        }
        if var views = json["bufferViews"] as? [[String: Any]] {
            for k in views.indices {
                let b = (views[k]["buffer"] as? Int) ?? 0
                views[k]["byteOffset"] = ((views[k]["byteOffset"] as? Int) ?? 0) + (b < base.count ? base[b] : 0)
                views[k]["buffer"] = 0
            }
            json["bufferViews"] = views
        }
        let images = json["images"] as? [[String: Any]] ?? []
        for (i, img) in images.enumerated() {
            guard let uri = img["uri"] as? String else { continue }
            let data: [UInt8]? = uri.hasPrefix("data:")
                ? uri.range(of: ";base64,").map { base64(String(uri[$0.upperBound...])) } : read(percentDecode(uri))
            guard let data else { continue }
            let lower = uri.lowercased()
            let mime = lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.contains("image/jpeg") ? "image/jpeg" : "image/png"
            let view = pushView(&json, &bin, data)
            var all = json["images"] as? [[String: Any]] ?? []
            all[i] = ["bufferView": view, "mimeType": mime, "name": img["name"] ?? NSNull()]
            json["images"] = all
        }
        json["buffers"] = [["byteLength": bin.count]]
        return try join(json, bin)
    }

    static func percentDecode(_ s: String) -> String {
        let b = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < b.count {
            if b[i] == UInt8(ascii: "%"), i + 2 < b.count, let v = UInt8(String(decoding: b[i + 1...i + 2], as: UTF8.self), radix: 16) {
                out.append(v)
                i += 3
                continue
            }
            out.append(b[i])
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func base64(_ s: String) -> [UInt8] {
        func val(_ c: UInt8) -> UInt32? {
            switch c {
            case 65...90: UInt32(c - 65)
            case 97...122: UInt32(c - 97 + 26)
            case 48...57: UInt32(c - 48 + 52)
            case 43, 45: 62
            case 47, 95: 63
            default: nil
            }
        }
        var out: [UInt8] = []
        var acc: UInt32 = 0, bits = 0
        for c in s.utf8 {
            if c == UInt8(ascii: "=") { break }
            guard let v = val(c) else { continue }
            acc = acc << 6 | v
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8(truncatingIfNeeded: acc >> UInt32(bits)))
            }
        }
        return out
    }

    static func uses(_ json: [String: Any], _ ext: String) -> Bool {
        ["extensionsUsed", "extensionsRequired"].contains { (json[$0] as? [String])?.contains(ext) ?? false }
    }

    static func expand(_ glb: [UInt8]) throws -> [UInt8]? {
        var (json, bin) = try split(glb)
        for ext in ["KHR_draco_mesh_compression", "KHR_texture_basisu"] where uses(json, ext) {
            throw Failure(description: "\(ext) glTF is not supported")
        }
        guard uses(json, "EXT_meshopt_compression") else { return nil }
        guard var views = json["bufferViews"] as? [[String: Any]] else { return nil }
        for v in views.indices {
            guard var exts = views[v]["extensions"] as? [String: Any], let e = exts["EXT_meshopt_compression"] as? [String: Any]
            else { continue }
            guard (e["buffer"] as? Int) == 0 else { throw Failure(description: "meshopt: only the GLB BIN is supported") }
            let off = e["byteOffset"] as? Int ?? 0, len = e["byteLength"] as? Int ?? 0
            guard off >= 0, len >= 0, off + len <= bin.count else { throw Failure(description: "meshopt: view out of range") }
            let stride = e["byteStride"] as? Int ?? 0, count = e["count"] as? Int ?? 0
            guard (e["mode"] as? String) == "ATTRIBUTES" else { throw Failure(description: "meshopt: mode \(e["mode"] ?? "") is not supported") }
            guard [4, 8, 12, 16, 20, 24, 28, 32].contains(stride) else { throw Failure(description: "meshopt: stride \(stride)") }
            guard count >= 0, count <= GLB.maxCount else { throw Failure(description: "meshopt: count \(count)") }
            var data = [UInt8](repeating: 0, count: count * stride)
            let rc = Array(bin[off..<off + len]).withUnsafeBufferPointer { src in
                data.withUnsafeMutableBytes { dst in
                    meshopt_decodeVertexBuffer(dst.baseAddress, count, stride, src.baseAddress, src.count)
                }
            }
            guard rc == 0 else { throw Failure(description: "meshopt: decode failed \(rc)") }
            let filter = e["filter"] as? String ?? "NONE"
            data.withUnsafeMutableBytes { d in
                switch (filter, stride) {
                case ("QUATERNION", 8): meshopt_decodeFilterQuat(d.baseAddress, count, 8)
                case ("OCTAHEDRAL", 4), ("OCTAHEDRAL", 8): meshopt_decodeFilterOct(d.baseAddress, count, stride)
                case ("EXPONENTIAL", _): meshopt_decodeFilterExp(d.baseAddress, count, stride)
                default: break
                }
            }
            guard ["NONE", "EXPONENTIAL"].contains(filter) || (filter, stride) == ("QUATERNION", 8)
                || (filter == "OCTAHEDRAL" && (stride == 4 || stride == 8)) else {
                throw Failure(description: "meshopt: filter \(filter) with stride \(stride) is not supported")
            }
            while bin.count % 4 != 0 { bin.append(0) }
            let at = bin.count
            bin += data
            exts.removeValue(forKey: "EXT_meshopt_compression")
            views[v]["extensions"] = exts
            views[v]["buffer"] = 0
            views[v]["byteOffset"] = at
            views[v]["byteLength"] = data.count
            views[v]["byteStride"] = stride
        }
        json["bufferViews"] = views
        for k in ["extensionsUsed", "extensionsRequired"] {
            if let a = json[k] as? [String] { json[k] = a.filter { $0 != "EXT_meshopt_compression" } }
        }
        json["buffers"] = [["byteLength": bin.count]]
        return try join(json, bin)
    }
}
