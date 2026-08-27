import Foundation
import Testing
@testable import GuiliuCore

@Suite("Ollama 本地文档分析")
struct OllamaTests {
    @Test("可读取只包含基础字段的持久化分析结果")
    func decodesMinimalPersistedAnalysis() throws {
        let json = """
        {
          "suggestion": {
            "category": "researchPapers",
            "confidence": 0.75,
            "reason": "基础分析依据"
          },
          "tags": [],
          "summary": "基础内容概括",
          "model": "example-model:minimal",
          "analyzedAt": 0
        }
        """

        let result = try JSONDecoder().decode(
            OllamaDocumentAnalysis.self,
            from: Data(json.utf8)
        )

        #expect(result.summary == "基础内容概括")
        #expect(result.paperApproach == nil)
        #expect(result.keyIdea == nil)
        #expect(result.keyPoints.isEmpty)
    }

    @Test("解析论文分类、智能标签和内容概括")
    func parsesPaperAnalysis() throws {
        let json = """
        {
          "category": "researchPapers",
          "confidence": 0.94,
          "reason": "正文包含摘要、方法和实验结论",
          "project": "示例项目",
          "organization": "示例科技有限公司",
          "document_type": "研究论文",
          "importance": "重要资料",
          "topics": ["示例主题", "本地推理"],
          "summary": "论文研究一个示例分类问题。方法结合特征提取与分类器。实验显示分类准确率得到提升。"
        }
        """

        let result = try OllamaClient.decodeAnalysisContent(json, model: "example-model:current")

        #expect(result.suggestion.category == .researchPapers)
        #expect(result.suggestion.confidence == 0.94)
        #expect(result.summary?.contains("示例分类") == true)
        #expect(result.tags.contains(SmartTag(kind: .organization, value: "示例科技有限公司")))
        #expect(result.tags.contains(SmartTag(kind: .project, value: "示例项目")))
    }

    @Test("非论文也会保存主要内容")
    func keepsSummaryForNonPaper() throws {
        let json = """
        {
          "category": "presentations",
          "confidence": 0.8,
          "reason": "识别为汇报材料",
          "project": "",
          "organization": "",
          "document_type": "演示文稿",
          "importance": "",
          "topics": ["汇报"],
          "summary": "不应保留"
        }
        """

        let result = try OllamaClient.decodeAnalysisContent(json, model: "example-model:current")
        #expect(result.suggestion.category == .presentations)
        #expect(result.summary == "不应保留")
    }

    @Test("拒绝不在固定集合中的模型分类")
    func rejectsInventedCategory() {
        let json = """
        {
          "category": "randomFolder",
          "confidence": 1,
          "reason": "",
          "project": "",
          "organization": "",
          "document_type": "",
          "importance": "",
          "topics": [],
          "summary": ""
        }
        """

        #expect(throws: OllamaError.invalidAnalysis) {
            _ = try OllamaClient.decodeAnalysisContent(json, model: "example-model:current")
        }
    }

    @Test("通用文档标签会本地化且自定义主题保持原样")
    func localizesGenericEnglishTags() throws {
        let json = """
        {
          "category": "researchPapers",
          "confidence": 0.9,
          "reason": "识别为科研论文",
          "project": "ExampleProject",
          "organization": "",
          "document_type": "researchPaper",
          "importance": "high",
          "topics": ["Example Topic"],
          "summary": "论文研究一个明确标记为示例的主题。"
        }
        """

        let result = try OllamaClient.decodeAnalysisContent(json, model: "example-model:current")
        #expect(result.tags.contains(SmartTag(kind: .project, value: "ExampleProject")))
        #expect(result.tags.contains(SmartTag(kind: .documentType, value: "研究论文")))
        #expect(result.tags.contains(SmartTag(kind: .importance, value: "重要资料")))
        #expect(result.tags.contains(SmartTag(kind: .topic, value: "Example Topic")))
    }

    @Test("论文只保留包含创新与具体实现的主要做法")
    func parsesStructuredPaperReading() throws {
        let json = """
        {
          "category": "researchPapers",
          "confidence": 0.91,
          "reason": "正文包含方法和实验章节",
          "project": "",
          "organization": "示例科技有限公司",
          "document_type": "研究论文",
          "importance": "",
          "topics": ["示例主题"],
          "paper_innovation": "提出双分支示例分类模型，以共享特征融合局部与全局信息。",
          "implementation_steps": [
            "输入编码：图像先经过标准化与尺寸调整。",
            "特征提取：两个通用编码分支分别提取局部与全局特征。",
            "联合训练：融合共享特征并使用交叉熵损失训练分类头。",
            "分类输出：分类头根据融合表征输出类别概率。"
          ],
          "key_idea": "提出双分支示例分类模型。",
          "method": "采用两个通用编码分支联合建模。",
          "experiments_and_results": "在三个公开数据集上优于对比方法。",
          "limitations": "当前文本未提供消融实验细节。",
          "main_content": "",
          "key_points": []
        }
        """

        let result = try OllamaClient.decodeAnalysisContent(json, model: "example-model:current")
        #expect(result.paperApproach?.contains("共享特征") == true)
        #expect(result.paperApproach?.contains("交叉熵损失") == true)
        #expect(result.paperApproach?.contains("4. 分类输出") == true)
        #expect(result.summary == result.paperApproach)
        #expect(result.experimentResults?.contains("三个公开数据集") == true)
        #expect(result.summary?.contains("三个公开数据集") == false)
        #expect(result.summary?.contains("消融实验") == false)
    }

    @Test("普通文档解析主要内容和关键事项")
    func parsesGeneralDocumentReading() throws {
        let json = """
        {
          "category": "recordsForms",
          "confidence": 0.86,
          "reason": "这是会议通知",
          "project": "",
          "organization": "",
          "document_type": "会议通知",
          "importance": "重要资料",
          "topics": ["会议安排"],
          "key_idea": "",
          "method": "",
          "experiments_and_results": "",
          "limitations": "",
          "main_content": "文档通知下周召开项目评审会。",
          "key_points": ["周一前提交材料", "会议地点为三层会议室"]
        }
        """

        let result = try OllamaClient.decodeAnalysisContent(json, model: "example-model:current")
        #expect(result.mainContent?.contains("项目评审会") == true)
        #expect(result.keyPoints.count == 2)
        #expect(result.summary?.contains("周一前提交材料") == true)
    }

    @Test("普通文档模型漏掉概括时使用正文生成可见兜底")
    func generalDocumentNeverPersistsBlankContent() throws {
        let blank = OllamaDocumentAnalysis(
            suggestion: ClassificationSuggestion(
                category: .documentsReports,
                reason: "文件当前位于文档与报告",
                confidence: 1
            ),
            tags: [],
            summary: nil,
            mainContent: nil,
            model: "example-model:current"
        )
        let text = "文档说明示例活动分为四个阶段推进。第一阶段完成需求收集与方案设计。中期开展公开测试并保留结果记录。参与者需要按时提交反馈。最终成果包括活动报告和使用手册。"

        let result = OllamaClient.ensuringGeneralContent(
            blank,
            extractedText: text,
            fileURL: URL(fileURLWithPath: "/tmp/example-document.docx")
        )

        #expect(result.mainContent?.contains("四个阶段") == true)
        #expect(result.mainContent?.contains("提交反馈") == true)
        #expect(result.summary == result.mainContent)
    }

    @Test("普通文档已有模型概括时不被提取式兜底覆盖")
    func keepsGeneratedGeneralContent() {
        let generated = OllamaDocumentAnalysis(
            suggestion: ClassificationSuggestion(category: .documentsReports, reason: "报告", confidence: 0.9),
            tags: [],
            summary: "模型生成的概括",
            mainContent: "模型生成的概括",
            model: "example-model:current"
        )

        let result = OllamaClient.ensuringGeneralContent(
            generated,
            extractedText: "另一段正文内容，不应覆盖模型结果。",
            fileURL: URL(fileURLWithPath: "/tmp/report.docx")
        )

        #expect(result.mainContent == "模型生成的概括")
    }

    @Test("来源 App、分类名和文件名不能冒充机构或项目")
    func rejectsHallucinatedEntityTags() throws {
        let json = """
        {
          "category": "researchPapers",
          "confidence": 0.6,
          "reason": "识别为论文",
          "project": "example-paper.pdf",
          "organization": "Safari",
          "document_type": "研究论文",
          "importance": "high",
          "topics": ["researchPapers"],
          "summary": "内容不足"
        }
        """

        let result = try OllamaClient.decodeAnalysisContent(
            json,
            model: "example-model:current",
            fileURL: URL(fileURLWithPath: "/tmp/example-paper.pdf"),
            origin: .safari
        )
        #expect(!result.tags.contains { $0.kind == .organization })
        #expect(!result.tags.contains { $0.kind == .project })
        #expect(!result.tags.contains { $0.value.lowercased() == "researchpapers" })
        #expect(result.tags.contains(SmartTag(kind: .importance, value: "重要资料")))
    }

    @Test("过滤占位符、分类赋值和零置信度伪结果")
    func rejectsPlaceholderAnalysis() throws {
        let json = """
        {
          "category": "documentsReports",
          "confidence": 0,
          "reason": "当前提取内容未提供……",
          "project": "当前提取内容未提供……",
          "organization": "",
          "document_type": "",
          "importance": "重要资料",
          "topics": ["researchPapers=科研论文"],
          "key_idea": "当前提取内容未提供……",
          "method": "当前提取内容未提供……",
          "experiments_and_results": "当前提取内容未提供……",
          "limitations": "当前提取内容未提供……",
          "main_content": "当前提取内容未提供……",
          "key_points": []
        }
        """
        let fallback = ClassificationSuggestion(
            category: .researchPapers,
            reason: "PDF 正文具有论文结构",
            confidence: 0.82
        )

        let result = try OllamaClient.decodeAnalysisContent(
            json,
            model: "example-model:current",
            fallbackSuggestion: fallback
        )

        #expect(result.suggestion == fallback)
        #expect(result.tags == [SmartTag(kind: .importance, value: "重要资料")])
        #expect(result.summary == nil)
        #expect(result.mainContent == nil)
    }
}
