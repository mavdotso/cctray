import Foundation
import Testing
@testable import cctray

struct CodexRPCTests {
    @Test func requestsManagedRefreshBeforeReadingLimits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("app-server.py")
        try """
        import json, sys
        for line in sys.stdin:
            message = json.loads(line)
            if 'id' not in message:
                continue
            method = message['method']
            if method == 'initialize':
                result = {}
            elif method == 'account/read':
                if message.get('params', {}).get('refreshToken') is not True:
                    print(json.dumps({'id': message['id'], 'error': {'message': 'Refresh required'}}), flush=True)
                    continue
                result = {'account': {'type': 'chatgpt', 'email': 'one@example.test'}}
            elif method == 'account/rateLimits/read':
                result = {'rateLimits': {'primary': {'usedPercent': 23, 'windowDurationMins': 300}}}
            else:
                raise RuntimeError(method)
            print(json.dumps({'id': message['id'], 'result': result}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)

        let (email, limits) = try CodexRPC.read(command: "/usr/bin/python3 " + Shell.quote(script.path))
        #expect(email == "one@example.test")
        #expect(limits.sessionWindow?.usedPercent == 23)
    }
}
