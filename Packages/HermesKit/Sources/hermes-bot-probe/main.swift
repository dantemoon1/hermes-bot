import Foundation
import HermesKit

// Lists the bots on a gateway. Read-only; for checking a connection from the command line.
let environment = ProcessInfo.processInfo.environment
guard let endpoint = GatewayEndpoint(environment["HERMES_URL"] ?? ""), let token = environment["HERMES_TOKEN"] else {
    print("Set HERMES_URL and HERMES_TOKEN.")
    exit(2)
}

let client = GatewayClient(endpoint: endpoint, token: token)
await client.connect()
do {
    for bot in try await client.listBots() {
        let preview = bot.chat?.preview.prefix(40) ?? ""
        print("\(bot.isDefault ? "*" : " ") \(bot.title)  [\(bot.name), \(bot.model ?? "no model")]  \(preview)")
    }
} catch {
    print("Failed: \(error)")
    exit(1)
}
await client.disconnect()
