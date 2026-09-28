import Foundation

enum LoginMethod: String, CaseIterable, Identifiable {
    case qr = "扫码"
    case password = "密码"
    case sms = "短信"
    case cookie = "Cookie"
    var id: Self { self }
}

enum LoginAction: String {
    case password = "auth.password"
    case sendSMS = "auth.sms.send"
    case sms = "auth.sms.login"
    case cookie = "auth.cookie"
    case captcha = "auth.captcha"
    case riskSend = "auth.risk.send"
    case riskVerify = "auth.risk.verify"
}

struct LoginRequestDTO: Encodable {
    var username: String?
    var password: String?
    var tel: String?
    var country_code: String?
    var code: String?
    var captcha_key: String?
    var cookie: String?
    var captcha: LoginCaptchaProof?
    var risk: LoginPhoneRisk?
}

struct LoginCaptchaProof: Encodable {
    let challenge: String
    let validate: String
    let seccode: String
    let token: String
}

struct LoginCaptchaChallenge: Decodable, Identifiable {
    let gt: String
    let challenge: String
    let token: String
    var id: String { token }
}

struct LoginPhoneRisk: Codable {
    let url: String
    let tmp_code: String
    let request_id: String
    let source: String
    let phone: String
}

enum LoginResultDTO: Decodable {
    case confirmed(PersistedSessionDTO)
    case captcha(LoginCaptchaChallenge)
    case phoneVerification(LoginPhoneRisk)
    case smsSent(String)

    private enum Keys: String, CodingKey { case status, session, captcha, risk, captcha_key }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "confirmed": self = .confirmed(try container.decode(PersistedSessionDTO.self, forKey: .session))
        case "captcha": self = .captcha(try container.decode(LoginCaptchaChallenge.self, forKey: .captcha))
        case "phone_verification": self = .phoneVerification(try container.decode(LoginPhoneRisk.self, forKey: .risk))
        case "sms_sent": self = .smsSent(try container.decode(String.self, forKey: .captcha_key))
        default: throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "未知登录响应类型")
        }
    }
}
