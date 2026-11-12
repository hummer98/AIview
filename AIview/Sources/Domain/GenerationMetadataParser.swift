import Foundation

/// 情報パネルに並べる名前付きの値。表示順を保つため辞書ではなく配列で持つ。
struct MetadataField: Sendable, Hashable {
    let label: String
    let value: String
}

/// 画像生成ツールが埋め込んだ metadata の解析結果。
struct GenerationMetadata: Sendable, Equatable {
    enum Source: String, Sendable {
        case swarmUI = "SwarmUI"
        case comfyUI = "ComfyUI"
        case automatic1111 = "Stable Diffusion WebUI"
    }

    let source: Source?
    let prompt: String?
    let negativePrompt: String?
    let fields: [MetadataField]

    static let empty = GenerationMetadata(source: nil, prompt: nil, negativePrompt: nil, fields: [])
}

/// 生成ツールごとの metadata 形式を見分けて、prompt と主要パラメータを取り出す。
///
/// 判別順:
/// 1. `parameters` が `sui_image_params` を持つ JSON → SwarmUI
/// 2. `parameters` がその他の文字列 → AUTOMATIC1111 形式のテキスト
/// 3. `prompt` が `class_type` を持つ node の JSON → ComfyUI（API 形式の node graph）
/// 4. `prompt` が JSON でない文字列 → その文字列を prompt として扱う
///
/// 入力は呼び出し側で 1 MiB 上限に制限済みであることを前提とする。
enum GenerationMetadataParser {
    static let maximumFieldCount = 40
    static let maximumFieldValueLength = 500
    private static let maximumGraphDepth = 16

    static func parse(parameters: String?, comfyPrompt: String?) -> GenerationMetadata {
        if let parameters, !parameters.isEmpty {
            if let swarm = parseSwarmUI(parameters) {
                return swarm
            }
            return parseAutomatic1111(parameters)
        }
        if let comfyPrompt, !comfyPrompt.isEmpty {
            if let comfy = parseComfyUI(comfyPrompt) {
                return comfy
            }
            let trimmed = comfyPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return GenerationMetadata(
                source: nil,
                prompt: trimmed.isEmpty ? nil : trimmed,
                negativePrompt: nil,
                fields: []
            )
        }
        return .empty
    }

    // MARK: - SwarmUI

    static func parseSwarmUI(_ text: String) -> GenerationMetadata? {
        guard let root = jsonObject(text) as? [String: Any],
              let params = root["sui_image_params"] as? [String: Any] else {
            return nil
        }

        var fields: [MetadataField] = []
        var consumed: Set<String> = ["prompt", "negativeprompt", "width", "height"]

        func append(_ label: String, key: String) {
            consumed.insert(key)
            if let value = params[key].flatMap(displayString) {
                fields.append(MetadataField(label: label, value: value))
            }
        }

        append("モデル", key: "model")
        append("seed", key: "seed")
        append("steps", key: "steps")
        append("CFG", key: "cfgscale")
        append("サンプラー", key: "sampler")
        append("スケジューラ", key: "scheduler")
        if let width = params["width"].flatMap(displayString),
           let height = params["height"].flatMap(displayString) {
            fields.append(MetadataField(label: "サイズ", value: "\(width) × \(height)"))
        }
        append("LoRA", key: "loras")
        append("VAE", key: "vae")

        // 既知以外の値も情報として残す（名前順で安定させる）。
        for key in params.keys.sorted() where !consumed.contains(key) {
            if let value = params[key].flatMap(displayString) {
                fields.append(MetadataField(label: key, value: value))
            }
        }

        if let extra = root["sui_extra_data"] as? [String: Any] {
            if let value = extra["generation_time"].flatMap(displayString) {
                fields.append(MetadataField(label: "生成時間", value: value))
            }
            if let value = extra["date"].flatMap(displayString) {
                fields.append(MetadataField(label: "生成日", value: value))
            }
        }

        return GenerationMetadata(
            source: .swarmUI,
            prompt: nonEmpty(params["prompt"] as? String),
            negativePrompt: nonEmpty(params["negativeprompt"] as? String),
            fields: bounded(fields)
        )
    }

    // MARK: - AUTOMATIC1111

    static func parseAutomatic1111(_ text: String) -> GenerationMetadata {
        var prompt: String?
        var negativePrompt: String?
        var settingsLine: String?

        if let negativeRange = text.range(of: "Negative prompt:", options: .caseInsensitive) {
            prompt = String(text[..<negativeRange.lowerBound])
            let afterNegative = text[negativeRange.upperBound...]
            if let stepsRange = afterNegative.range(of: "Steps:", options: .caseInsensitive) {
                negativePrompt = String(afterNegative[..<stepsRange.lowerBound])
                settingsLine = String(afterNegative[stepsRange.lowerBound...])
            } else {
                negativePrompt = String(afterNegative)
            }
        } else if let stepsRange = text.range(of: "Steps:", options: .caseInsensitive) {
            prompt = String(text[..<stepsRange.lowerBound])
            settingsLine = String(text[stepsRange.lowerBound...])
        } else {
            prompt = text
        }

        let fields = settingsLine.map(parseAutomatic1111Settings) ?? []
        return GenerationMetadata(
            source: settingsLine == nil ? nil : .automatic1111,
            prompt: nonEmpty(prompt),
            negativePrompt: nonEmpty(negativePrompt),
            fields: bounded(fields)
        )
    }

    /// `Steps: 20, Sampler: Euler a, CFG scale: 7, Lora hashes: "a: 1, b: 2"` を分解する。
    /// 引用符内のカンマでは区切らない。
    private static func parseAutomatic1111Settings(_ line: String) -> [MetadataField] {
        var fields: [MetadataField] = []
        var current = ""
        var inQuotes = false
        var segments: [String] = []
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == ",", !inQuotes {
                segments.append(current)
                current = ""
            } else if character == "\n", !inQuotes {
                segments.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        segments.append(current)

        for segment in segments {
            guard let colon = segment.firstIndex(of: ":") else { continue }
            let label = segment[..<colon].trimmingCharacters(in: .whitespaces)
            var value = segment[segment.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            guard !label.isEmpty, !value.isEmpty else { continue }
            fields.append(MetadataField(label: label, value: value))
        }
        return fields
    }

    // MARK: - ComfyUI

    private typealias ComfyGraph = [String: [String: Any]]

    /// ComfyUI の API 形式 graph（`{"<id>": {"class_type": ..., "inputs": {...}}}`）を解析する。
    ///
    /// sampler node の `positive` / `negative`（または guider 経由）から text encode node を辿って
    /// prompt を求める。node 構成は workflow ごとに自由なので、辿れなければ text を持つ node を
    /// id 順に集めて prompt とする。
    static func parseComfyUI(_ text: String) -> GenerationMetadata? {
        guard let root = jsonObject(text) as? [String: Any] else { return nil }
        var graph: ComfyGraph = [:]
        for (id, value) in root {
            if let node = value as? [String: Any], node["class_type"] is String {
                graph[id] = node
            }
        }
        guard !graph.isEmpty else { return nil }

        let sortedIDs = graph.keys.sorted(by: nodeIDLessThan)
        let sampler = sortedIDs.first { id in
            let inputs = Self.inputs(graph[id])
            return linkTarget(inputs["positive"]) != nil && (graph[id]?["class_type"] as? String)?.contains("Sampler") == true
        } ?? sortedIDs.first { linkTarget(Self.inputs(graph[$0])["guider"]) != nil }
            ?? sortedIDs.first { linkTarget(Self.inputs(graph[$0])["positive"]) != nil }

        var positiveRoot: String?
        var negativeRoot: String?
        if let sampler {
            let samplerInputs = inputs(graph[sampler])
            var conditioningOwner = samplerInputs
            if linkTarget(samplerInputs["positive"]) == nil,
               let guider = linkTarget(samplerInputs["guider"]) {
                conditioningOwner = inputs(graph[guider])
            }
            positiveRoot = linkTarget(conditioningOwner["positive"]) ?? linkTarget(conditioningOwner["conditioning"])
            negativeRoot = linkTarget(conditioningOwner["negative"])
        }

        var prompt = positiveRoot.map { joinedTexts(from: $0, graph: graph) } ?? nil
        let negativePrompt = negativeRoot.map { joinedTexts(from: $0, graph: graph) } ?? nil
        if prompt == nil, positiveRoot == nil {
            // sampler を特定できない graph は、text を持つ node を id 順に集める。
            let texts = sortedIDs.compactMap { textValue(of: $0, graph: graph, depth: 0) }
            prompt = nonEmpty(texts.joined(separator: "\n\n"))
        }

        return GenerationMetadata(
            source: .comfyUI,
            prompt: prompt,
            negativePrompt: negativePrompt,
            fields: bounded(comfyFields(graph: graph, sortedIDs: sortedIDs, sampler: sampler))
        )
    }

    private static func comfyFields(graph: ComfyGraph, sortedIDs: [String], sampler: String?) -> [MetadataField] {
        var fields: [MetadataField] = []
        var seen: Set<String> = []

        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            let key = "\(label)\u{0}\(value)"
            guard seen.insert(key).inserted else { return }
            fields.append(MetadataField(label: label, value: value))
        }

        // モデルと LoRA は graph 全体から集める。
        for id in sortedIDs {
            let inputs = inputs(graph[id])
            add("モデル", scalar(inputs["ckpt_name"]))
            add("モデル", scalar(inputs["unet_name"]))
        }
        for id in sortedIDs {
            add("LoRA", scalar(inputs(graph[id])["lora_name"]))
        }

        // sampler 自身と、直接つながる node（RandomNoise / BasicScheduler / KSamplerSelect など）の値。
        if let sampler {
            let samplerInputs = inputs(graph[sampler])
            var related = [sampler]
            for key in samplerInputs.keys.sorted() {
                if let target = linkTarget(samplerInputs[key]) {
                    related.append(target)
                }
            }
            let labels: [(key: String, label: String)] = [
                ("seed", "seed"), ("noise_seed", "seed"), ("steps", "steps"), ("cfg", "CFG"),
                ("sampler_name", "サンプラー"), ("scheduler", "スケジューラ"),
                ("denoise", "denoise")
            ]
            for (key, label) in labels {
                for id in related {
                    if let value = scalar(inputs(graph[id])[key]) {
                        add(label, value)
                        break
                    }
                }
            }
            // FluxGuidance は sampler の直接の入力ではなく conditioning の途中にあるため graph 全体から探す。
            if let guidance = sortedIDs.lazy.compactMap({ scalar(Self.inputs(graph[$0])["guidance"]) }).first {
                add("guidance", guidance)
            }
        }

        // latent 生成 node のサイズ。
        for id in sortedIDs {
            guard let classType = graph[id]?["class_type"] as? String, classType.contains("Latent") else { continue }
            let inputs = inputs(graph[id])
            if let width = scalar(inputs["width"]), let height = scalar(inputs["height"]) {
                add("サイズ", "\(width) × \(height)")
                break
            }
        }
        return fields
    }

    /// conditioning を遡り、text encode node の text を集める。
    private static func joinedTexts(from nodeID: String, graph: ComfyGraph) -> String? {
        var visited: Set<String> = []
        var texts: [String] = []
        collectTexts(from: nodeID, graph: graph, depth: 0, visited: &visited, into: &texts)
        return nonEmpty(texts.joined(separator: "\n\n"))
    }

    private static func collectTexts(
        from nodeID: String,
        graph: ComfyGraph,
        depth: Int,
        visited: inout Set<String>,
        into texts: inout [String]
    ) {
        guard depth <= maximumGraphDepth, visited.insert(nodeID).inserted else { return }
        if let text = textValue(of: nodeID, graph: graph, depth: depth) {
            texts.append(text)
            return
        }
        // ConditioningCombine / FluxGuidance / ControlNetApply などの中継 node は
        // conditioning 系の入力だけを辿る（model / clip / image へは進まない）。
        let inputs = inputs(graph[nodeID])
        for key in inputs.keys.sorted() where key.lowercased().contains("conditioning") || key == "positive" {
            if let target = linkTarget(inputs[key]) {
                collectTexts(from: target, graph: graph, depth: depth + 1, visited: &visited, into: &texts)
            }
        }
    }

    /// text encode 系 node の text。`text` が別 node（primitive / string 系）へのリンクなら値を辿る。
    private static func textValue(of nodeID: String, graph: ComfyGraph, depth: Int) -> String? {
        guard depth <= maximumGraphDepth, let node = graph[nodeID] else { return nil }
        let inputs = inputs(node)
        let classType = node["class_type"] as? String ?? ""
        let isTextEncoder = classType.contains("TextEncode")
        for key in ["text", "text_g", "text_l", "prompt"] {
            if let text = inputs[key] as? String, isTextEncoder || key == "text" {
                if let value = nonEmpty(text) { return value }
            } else if isTextEncoder, let target = linkTarget(inputs[key]) {
                if let value = stringValue(of: target, graph: graph, depth: depth + 1) { return value }
            }
        }
        return nil
    }

    private static func stringValue(of nodeID: String, graph: ComfyGraph, depth: Int) -> String? {
        guard depth <= maximumGraphDepth else { return nil }
        let inputs = inputs(graph[nodeID])
        for key in ["value", "string", "text", "prompt"] {
            if let text = inputs[key] as? String, let value = nonEmpty(text) {
                return value
            }
            if let target = linkTarget(inputs[key]),
               let value = stringValue(of: target, graph: graph, depth: depth + 1) {
                return value
            }
        }
        return nil
    }

    private static func inputs(_ node: [String: Any]?) -> [String: Any] {
        node?["inputs"] as? [String: Any] ?? [:]
    }

    /// ComfyUI のリンクは `["<node id>", <output index>]`。
    private static func linkTarget(_ value: Any?) -> String? {
        guard let array = value as? [Any], array.count == 2, array[1] is NSNumber else { return nil }
        if let id = array[0] as? String { return id }
        if let id = array[0] as? NSNumber { return id.stringValue }
        return nil
    }

    private static func scalar(_ value: Any?) -> String? {
        guard let value, linkTarget(value) == nil else { return nil }
        if value is [Any] || value is [String: Any] { return nil }
        return displayString(value)
    }

    private static func nodeIDLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    // MARK: - Helpers

    private static func jsonObject(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func displayString(_ value: Any) -> String? {
        let string: String?
        switch value {
        case let text as String:
            string = text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                string = number.boolValue ? "true" : "false"
            } else {
                string = number.stringValue
            }
        case let array as [Any]:
            let items = array.compactMap { item -> String? in
                if let dictionary = item as? [String: Any] {
                    return (dictionary["name"] ?? dictionary["model"]).flatMap(displayString)
                }
                return displayString(item)
            }
            string = items.isEmpty ? nil : items.joined(separator: ", ")
        default:
            string = nil
        }
        guard let trimmed = nonEmpty(string) else { return nil }
        if trimmed.count > maximumFieldValueLength {
            return String(trimmed.prefix(maximumFieldValueLength)) + "…"
        }
        return trimmed
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func bounded(_ fields: [MetadataField]) -> [MetadataField] {
        Array(fields.prefix(maximumFieldCount))
    }
}
