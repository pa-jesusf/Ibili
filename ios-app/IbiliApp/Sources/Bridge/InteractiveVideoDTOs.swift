import Foundation

public struct InteractiveVideoInfoDTO: Codable {
    public let graphVersion: Int64
    public let historyNode: InteractiveHistoryNodeDTO?
    public let msg: String?
    public let needReload: Int?
    enum CodingKeys: String, CodingKey {
        case graphVersion = "graph_version", historyNode = "history_node", msg
        case needReload = "need_reload"
    }
}

public struct InteractiveHistoryNodeDTO: Codable {
    public let nodeID: Int64
    public let cid: Int64
    public let title: String
    enum CodingKeys: String, CodingKey { case nodeID = "node_id", cid, title }
}

public struct InteractiveNodeDTO: Codable, Equatable {
    public let edgeID: Int64
    public var title: String = ""
    public var isLeaf: Int = 0
    public var noBacktracking: Int = 0
    public var storyList: [InteractiveStoryDTO] = []
    public var hiddenVars: [InteractiveVariableDTO] = []
    public var edges: InteractiveEdgesDTO = .init()
    enum CodingKeys: String, CodingKey {
        case edgeID = "edge_id", title, isLeaf = "is_leaf", noBacktracking = "no_backtracking"
        case storyList = "story_list", hiddenVars = "hidden_vars", edges
    }
}

public struct InteractiveStoryDTO: Codable, Equatable {
    public let edgeID: Int64
    public let cid: Int64
    public var title: String = ""
    public var startPos: Int64 = 0
    enum CodingKeys: String, CodingKey { case edgeID = "edge_id", cid, title, startPos = "start_pos" }
}

public struct InteractiveEdgesDTO: Codable, Equatable {
    public var questions: [InteractiveQuestionDTO] = []
}

public struct InteractiveQuestionDTO: Codable, Equatable {
    public var id: Int64 = 0
    public var type: Int = 1
    public var startTime: Int64 = 0
    public var startTimeR: Int64 = 0
    public var duration: Int64 = -1
    public var pauseVideo: Int = 1
    public var title: String = ""
    public var choices: [InteractiveChoiceDTO] = []
    enum CodingKeys: String, CodingKey {
        case id, type, startTime = "start_time", startTimeR = "start_time_r", duration
        case pauseVideo = "pause_video", title, choices
    }

    // Public Bilibili web player: type 4 is an in-video decision. Other
    // ordinary types are at the end, or `duration` ms before the end.
    func triggerSeconds(videoDuration: Double) -> Double {
        if type == 4 {
            return max(0, startTime > 0 ? Double(startTime) / 1000 : videoDuration - Double(startTimeR) / 1000)
        }
        return duration > 0 ? max(0, videoDuration - Double(duration) / 1000) : videoDuration
    }
}

public struct InteractiveChoiceDTO: Codable, Equatable, Identifiable {
    public let id: Int64
    public var cid: Int64 = 0
    public var option: String = ""
    public var condition: String = ""
    public var nativeAction: String = ""
    public var platformAction: String = ""
    public var isDefault: Int = 0
    public var isHidden: Int = 0
    enum CodingKeys: String, CodingKey {
        case id, cid, option, condition, nativeAction = "native_action", platformAction = "platform_action"
        case isDefault = "is_default", isHidden = "is_hidden"
    }
}

public struct InteractiveVariableDTO: Codable, Equatable {
    public var id: String = ""
    public let idV2: String
    public var type: Int = 1
    public var name: String = ""
    public var value: Double = 0
    public var isShow: Int = 0
    enum CodingKeys: String, CodingKey { case id, idV2 = "id_v2", type, name, value, isShow = "is_show" }
}
