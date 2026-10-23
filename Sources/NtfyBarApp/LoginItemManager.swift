import Foundation
import ServiceManagement

protocol LoginItemManaging {
    func setEnabled(_ enabled: Bool) throws
}

struct LoginItemManager: LoginItemManaging {
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}
