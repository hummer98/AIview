import XCTest
@testable import AIview

/// SwarmUI / ComfyUI / AUTOMATIC1111 の metadata 形式を判別して解析できることを検証する。
final class GenerationMetadataParserTests: XCTestCase {
    // SwarmUI 0.9.8 が `parameters` tEXt に書く JSON（実ファイルから採取した構造）。
    static let swarmUIParameters = """
    {
      "sui_image_params": {
        "seed": 1234,
        "model": "snofs-klein9b-distilled-v14-fp8",
        "steps": 8,
        "cfgscale": 1.0,
        "width": 896,
        "height": 1152,
        "prompt": "A candid photorealistic photograph of a woman by the seaside.",
        "negativeprompt": "",
        "swarm_version": "0.9.8.3"
      },
      "sui_extra_data": {
        "date": "2026-09-21",
        "prep_time": "2.00 sec",
        "generation_time": "16.99 sec"
      },
      "sui_models": [
        { "name": "snofs-klein9b-distilled-v14-fp8.safetensors", "param": "model", "hash": "0x0e" }
      ]
    }
    """

    // ComfyUI 標準 workflow（KSampler + CLIPTextEncode）の API 形式 graph。
    static let comfyKSamplerPrompt = """
    {
      "3": {"class_type": "KSampler", "inputs": {"seed": 42, "steps": 20, "cfg": 7.5,
            "sampler_name": "euler", "scheduler": "normal", "denoise": 1,
            "model": ["4", 0], "positive": ["6", 0], "negative": ["7", 0], "latent_image": ["5", 0]}},
      "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "sdxl_base.safetensors"}},
      "5": {"class_type": "EmptyLatentImage", "inputs": {"width": 1024, "height": 768, "batch_size": 1}},
      "6": {"class_type": "CLIPTextEncode", "inputs": {"text": "a red fox in snow", "clip": ["4", 1]}},
      "7": {"class_type": "CLIPTextEncode", "inputs": {"text": "blurry, lowres", "clip": ["4", 1]}},
      "8": {"class_type": "VAEDecode", "inputs": {"samples": ["3", 0], "vae": ["4", 2]}},
      "9": {"class_type": "SaveImage", "inputs": {"filename_prefix": "ComfyUI", "images": ["8", 0]}}
    }
    """

    func testSwarmUIJSONIsRecognizedAndMapped() throws {
        let result = GenerationMetadataParser.parse(parameters: Self.swarmUIParameters, comfyPrompt: nil)

        XCTAssertEqual(result.source, .swarmUI)
        XCTAssertEqual(result.prompt, "A candid photorealistic photograph of a woman by the seaside.")
        XCTAssertNil(result.negativePrompt, "空のネガティブプロンプトは表示しない")
        XCTAssertEqual(value(result, "モデル"), "snofs-klein9b-distilled-v14-fp8")
        XCTAssertEqual(value(result, "seed"), "1234")
        XCTAssertEqual(value(result, "steps"), "8")
        XCTAssertEqual(value(result, "CFG"), "1")
        XCTAssertEqual(value(result, "サイズ"), "896 × 1152")
        XCTAssertEqual(value(result, "生成時間"), "16.99 sec")
        XCTAssertEqual(value(result, "swarm_version"), "0.9.8.3")
        XCTAssertFalse(result.fields.contains { $0.value.contains("sui_image_params") })
    }

    func testAutomatic1111TextKeepsPromptsAndSplitsSettings() {
        let text = """
        masterpiece, castle
        Negative prompt: lowres, bad hands
        Steps: 30, Sampler: DPM++ 2M, CFG scale: 7, Seed: 99, Lora hashes: "a: 1, b: 2"
        """

        let result = GenerationMetadataParser.parse(parameters: text, comfyPrompt: nil)

        XCTAssertEqual(result.source, .automatic1111)
        XCTAssertEqual(result.prompt, "masterpiece, castle")
        XCTAssertEqual(result.negativePrompt, "lowres, bad hands")
        XCTAssertEqual(value(result, "Steps"), "30")
        XCTAssertEqual(value(result, "Sampler"), "DPM++ 2M")
        XCTAssertEqual(value(result, "Lora hashes"), "a: 1, b: 2", "引用符内のカンマで分割しない")
    }

    func testBrokenJSONInParametersFallsBackToPlainText() {
        let result = GenerationMetadataParser.parse(parameters: "{not json", comfyPrompt: nil)

        XCTAssertNil(result.source)
        XCTAssertEqual(result.prompt, "{not json")
    }

    func testComfyUIKSamplerGraphResolvesPositiveAndNegative() {
        let result = GenerationMetadataParser.parse(parameters: nil, comfyPrompt: Self.comfyKSamplerPrompt)

        XCTAssertEqual(result.source, .comfyUI)
        XCTAssertEqual(result.prompt, "a red fox in snow")
        XCTAssertEqual(result.negativePrompt, "blurry, lowres")
        XCTAssertEqual(value(result, "モデル"), "sdxl_base.safetensors")
        XCTAssertEqual(value(result, "seed"), "42")
        XCTAssertEqual(value(result, "steps"), "20")
        XCTAssertEqual(value(result, "CFG"), "7.5")
        XCTAssertEqual(value(result, "サンプラー"), "euler")
        XCTAssertEqual(value(result, "サイズ"), "1024 × 768")
    }

    func testComfyUIFluxGuiderGraphFollowsGuiderAndConditioningRelays() {
        let graph = """
        {
          "10": {"class_type": "SamplerCustomAdvanced", "inputs": {"noise": ["11", 0], "guider": ["12", 0],
                 "sampler": ["13", 0], "sigmas": ["14", 0], "latent_image": ["15", 0]}},
          "11": {"class_type": "RandomNoise", "inputs": {"noise_seed": 777}},
          "12": {"class_type": "BasicGuider", "inputs": {"model": ["16", 0], "conditioning": ["17", 0]}},
          "13": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler"}},
          "14": {"class_type": "BasicScheduler", "inputs": {"scheduler": "simple", "steps": 25, "denoise": 1, "model": ["16", 0]}},
          "15": {"class_type": "EmptySD3LatentImage", "inputs": {"width": 832, "height": 1216, "batch_size": 1}},
          "16": {"class_type": "UNETLoader", "inputs": {"unet_name": "flux1-dev.safetensors", "weight_dtype": "fp8"}},
          "17": {"class_type": "FluxGuidance", "inputs": {"guidance": 3.5, "conditioning": ["18", 0]}},
          "18": {"class_type": "CLIPTextEncode", "inputs": {"text": ["19", 0], "clip": ["20", 0]}},
          "19": {"class_type": "PrimitiveString", "inputs": {"value": "a lighthouse at dusk"}},
          "20": {"class_type": "DualCLIPLoader", "inputs": {"clip_name1": "t5xxl.safetensors", "clip_name2": "clip_l.safetensors"}}
        }
        """

        let result = GenerationMetadataParser.parse(parameters: nil, comfyPrompt: graph)

        XCTAssertEqual(result.source, .comfyUI)
        XCTAssertEqual(result.prompt, "a lighthouse at dusk", "guider → FluxGuidance → CLIPTextEncode → primitive を辿る")
        XCTAssertNil(result.negativePrompt)
        XCTAssertEqual(value(result, "モデル"), "flux1-dev.safetensors")
        XCTAssertEqual(value(result, "seed"), "777")
        XCTAssertEqual(value(result, "steps"), "25")
        XCTAssertEqual(value(result, "サンプラー"), "euler")
        XCTAssertEqual(value(result, "guidance"), "3.5")
        XCTAssertEqual(value(result, "サイズ"), "832 × 1216")
    }

    func testComfyUIGraphWithoutSamplerCollectsTextEncoders() {
        let graph = """
        {"1": {"class_type": "CLIPTextEncode", "inputs": {"text": "first"}},
         "2": {"class_type": "CLIPTextEncode", "inputs": {"text": "second"}}}
        """

        let result = GenerationMetadataParser.parse(parameters: nil, comfyPrompt: graph)

        XCTAssertEqual(result.source, .comfyUI)
        XCTAssertEqual(result.prompt, "first\n\nsecond")
    }

    func testParametersTakePrecedenceOverComfyPrompt() {
        let result = GenerationMetadataParser.parse(
            parameters: Self.swarmUIParameters,
            comfyPrompt: Self.comfyKSamplerPrompt
        )
        XCTAssertEqual(result.source, .swarmUI)
    }

    func testNonGraphPromptChunkIsShownAsPlainPrompt() {
        let result = GenerationMetadataParser.parse(parameters: nil, comfyPrompt: "  just a prompt  ")

        XCTAssertNil(result.source)
        XCTAssertEqual(result.prompt, "just a prompt")
    }

    func testCyclicComfyGraphTerminates() {
        let graph = """
        {"1": {"class_type": "KSampler", "inputs": {"positive": ["2", 0]}},
         "2": {"class_type": "ConditioningCombine", "inputs": {"conditioning_1": ["3", 0]}},
         "3": {"class_type": "ConditioningCombine", "inputs": {"conditioning_1": ["2", 0]}}}
        """

        let result = GenerationMetadataParser.parse(parameters: nil, comfyPrompt: graph)

        XCTAssertEqual(result.source, .comfyUI)
        XCTAssertNil(result.prompt)
    }

    private func value(_ metadata: GenerationMetadata, _ label: String) -> String? {
        metadata.fields.first { $0.label == label }?.value
    }
}
