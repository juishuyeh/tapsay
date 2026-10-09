// swift-tools-version: 5.10
import PackageDescription

// 三個平台共用的核心：設定、API、錄音、App 與鍵盤之間的溝通。
// 刻意維持 Swift 5 語言模式，避免 Swift 6 嚴格並行檢查擋住音訊執行緒的寫法。
let package = Package(
    name: "TapSayKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TapSayKit", targets: ["TapSayKit"]),
    ],
    targets: [
        .target(name: "TapSayKit"),
        .testTarget(name: "TapSayKitTests", dependencies: ["TapSayKit"]),
    ]
)
