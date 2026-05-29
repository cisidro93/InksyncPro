import Foundation
import Network
import ZIPFoundation
import UIKit
import SwiftData

@MainActor
public final class BetaKindleService: ObservableObject {
    @Published public var isConverting = false
    @Published public var conversionProgress: Double = 0
    @Published public var conversionError: String?
    
    // Wi-Fi Server
    @Published public var isServerRunning = false
    @Published public var serverPort: UInt16 = 8080
    @Published public var serverIP: String = "127.0.0.1"
    @Published public var activeConnections = 0
    @Published public var serverURLString: String = ""
    
    private var listener: NWListener?
    private var bonjourService: NetService?
    private let modelContext: ModelContext
    
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    // MARK: - EPUB Conversion Pipeline
    
    /// Converts a comic/manga book to a Kindle-safe fixed-layout EPUB file.
    public func convertToEPUB(book: BetaBook) async throws -> URL {
        isConverting = true
        conversionProgress = 0.0
        conversionError = nil
        
        defer {
            isConverting = false
        }
        
        let fileManager = FileManager.default
        let bookURL = book.resolvedURL
        
        // 1. Extract files to temp folder
        conversionProgress = 0.1
        let extraction = try await BetaArchiveService.shared.extractComic(from: bookURL)
        let tempDir = extraction.workingDir
        let images = extraction.imageURLs
        
        defer {
            try? fileManager.removeItem(at: tempDir)
        }
        
        // 2. Prepare directories for EPUB construction
        conversionProgress = 0.3
        let epubDir = tempDir.appendingPathComponent("EPUB_Builder")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        let textDir = oebpsDir.appendingPathComponent("text")
        let imagesDestDir = oebpsDir.appendingPathComponent("images")
        let cssDir = oebpsDir.appendingPathComponent("css")
        
        try fileManager.createDirectory(at: textDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: imagesDestDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cssDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        
        // 3. Write basic EPUB files
        try "application/epub+zip".write(to: epubDir.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)
        
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        let cssContent = """
        @page { margin: 0; padding: 0; }
        body { margin: 0; padding: 0; width: 100vw; height: 100vh; background-color: #000000; }
        div.svg-wrapper { width: 100%; height: 100%; margin: 0; padding: 0; text-align: center; }
        img { height: 100%; width: auto; max-width: 100%; object-fit: contain; }
        """
        try cssContent.write(to: cssDir.appendingPathComponent("comic.css"), atomically: true, encoding: .utf8)
        
        // 4. Copy images and generate pages
        var manifestItems: [String] = []
        var spineItems: [String] = []
        
        manifestItems.append("<item id=\"css\" href=\"css/comic.css\" media-type=\"text/css\"/>")
        manifestItems.append("<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>")
        manifestItems.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        
        let bookUUID = UUID().uuidString
        var firstImageSize = CGSize(width: 1200, height: 1600)
        
        for (index, imgURL) in images.enumerated() {
            let imgName = String(format: "page_%04d.jpg", index + 1)
            let destImgURL = imagesDestDir.appendingPathComponent(imgName)
            
            // Re-save image as jpeg
            if let image = UIImage(contentsOfFile: imgURL.path) {
                if index == 0 {
                    firstImageSize = image.size
                }
                if let data = image.jpegData(compressionQuality: 0.85) {
                    try data.write(to: destImgURL)
                }
            } else {
                try fileManager.copyItem(at: imgURL, to: destImgURL)
            }
            
            // XHTML Chunk page
            let chunkName = String(format: "page_%04d.xhtml", index + 1)
            let chunkContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head>
                <title>Page \(index + 1)</title>
                <meta name="viewport" content="width=\(Int(firstImageSize.width)), height=\(Int(firstImageSize.height))"/>
                <link rel="stylesheet" type="text/css" href="../css/comic.css"/>
            </head>
            <body>
                <div class="svg-wrapper">
                    <img src="../images/\(imgName)" alt="Page \(index + 1)"/>
                </div>
            </body>
            </html>
            """
            try chunkContent.write(to: textDir.appendingPathComponent(chunkName), atomically: true, encoding: .utf8)
            
            manifestItems.append("<item id=\"img_\(index + 1)\" href=\"images/\(imgName)\" media-type=\"image/jpeg\"/>")
            manifestItems.append("<item id=\"chunk_\(index + 1)\" href=\"text/\(chunkName)\" media-type=\"application/xhtml+xml\"/>")
            spineItems.append("<itemref idref=\"chunk_\(index + 1)\"/>")
            
            conversionProgress = 0.3 + (0.5 * Double(index + 1) / Double(images.count))
        }
        
        // 5. Generate NAV/NCX
        let navContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en">
        <head><title>Navigation</title><meta charset="utf-8"/></head>
        <body>
            <nav epub:type="toc"><h1>Table of Contents</h1><ol><li><a href="text/page_0001.xhtml">Start</a></li></ol></nav>
        </body>
        </html>
        """
        try navContent.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        
        let ncxContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head><meta name="dtb:uid" content="urn:uuid:\(bookUUID)"/></head>
            <docTitle><text>\(book.title)</text></docTitle>
            <navMap>
                <navPoint id="nav-1" playOrder="1"><navLabel><text>Start</text></navLabel><content src="text/page_0001.xhtml"/></navPoint>
            </navMap>
        </ncx>
        """
        try ncxContent.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
        
        // 6. Generate content.opf
        let direction = (book.contentType == .manga) ? "rtl" : "ltr"
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="BookID">urn:uuid:\(bookUUID)</dc:identifier>
                <dc:title>\(book.title.xmlEscaped())</dc:title>
                <dc:creator>Inksync Beta</dc:creator>
                <dc:language>en</dc:language>
                <meta name="comic-panel-view" content="guided"/>
                <meta name="cover" content="img_1"/>
                <meta name="rendition:layout" content="pre-paginated"/>
                <meta name="rendition:spread" content="none"/>
            </metadata>
            <manifest>
                \(manifestItems.joined(separator: "\n        "))
            </manifest>
            <spine page-progression-direction="\(direction)">
                \(spineItems.joined(separator: "\n        "))
            </spine>
        </package>
        """
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        // 7. Zip everything to final .epub output
        conversionProgress = 0.9
        let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let outputURL = documentsDir.appendingPathComponent("Library/\(book.id)_Kindle.epub")
        
        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }
        
        guard let archive = try? Archive(url: outputURL, accessMode: .create, pathEncoding: .utf8) else {
            throw NSError(domain: "BetaKindleService", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to create ZIP Archive for EPUB."])
        }
        
        // EPUB formatting requires uncompressed mimetype as first entry
        let mimetypePath = epubDir.appendingPathComponent("mimetype")
        try archive.addEntry(with: "mimetype", fileURL: mimetypePath, compressionMethod: .none)
        try archive.addEntry(with: "META-INF/container.xml", fileURL: metaInfDir.appendingPathComponent("container.xml"), compressionMethod: .deflate)
        
        let enumerator = fileManager.enumerator(at: oebpsDir, includingPropertiesForKeys: nil)!
        while let fileURL = enumerator.nextObject() as? URL {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues.isDirectory == true { continue }
            
            if let relPath = fileURL.path.components(separatedBy: "\(epubDir.path)/").last {
                try archive.addEntry(with: relPath, fileURL: fileURL, compressionMethod: .deflate)
            }
        }
        
        conversionProgress = 1.0
        return outputURL
    }
    
    // MARK: - Wi-Fi Local Sideload Server
    
    public func startServer() {
        guard !isServerRunning else { return }
        
        let ip = getIPAddress() ?? "127.0.0.1"
        self.serverIP = ip
        
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            
            let serverListener = try NWListener(using: params, on: 8080)
            serverListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        self.isServerRunning = true
                        let port = serverListener.port?.rawValue ?? 8080
                        self.serverPort = port
                        self.serverURLString = "http://\(self.serverIP):\(port)"
                        self.advertiseService(port: port)
                        print("BetaWiFiServer: Listening on \(self.serverURLString)")
                    case .failed(let err):
                        print("BetaWiFiServer: Listener failed: \(err)")
                        self.stopServer()
                    default:
                        break
                    }
                }
            }
            
            serverListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleConnection(connection)
                }
            }
            
            serverListener.start(queue: .global(qos: .userInitiated))
            self.listener = serverListener
            
        } catch {
            print("BetaWiFiServer: Failed to start listener: \(error)")
            self.conversionError = "Could not start local server: \(error.localizedDescription)"
        }
    }
    
    public func stopServer() {
        listener?.cancel()
        listener = nil
        bonjourService?.stop()
        bonjourService = nil
        isServerRunning = false
        serverURLString = ""
        activeConnections = 0
    }
    
    private func advertiseService(port: UInt16) {
        bonjourService?.stop()
        let service = NetService(domain: "local.", type: "_http._tcp.", name: "Inksync Beta Library", port: Int32(port))
        service.publish()
        bonjourService = service
    }
    
    private func handleConnection(_ connection: NWConnection) {
        activeConnections += 1
        connection.start(queue: .global(qos: .default))
        
        // Read HTTP request
        readRequest(connection: connection)
    }
    
    private func readRequest(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }
                if let data = data, !data.isEmpty, let requestStr = String(data: data, encoding: .utf8) {
                    self.processHTTPRequest(requestStr, connection: connection)
                } else {
                    if isComplete || error != nil {
                        self.closeConnection(connection)
                    }
                }
            }
        }
    }
    
    private func processHTTPRequest(_ request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection, statusCode: 400, html: "Bad Request")
            return
        }
        
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection, statusCode: 400, html: "Bad Request")
            return
        }
        
        let method = parts[0]
        let rawPath = parts[1]
        let path = rawPath.removingPercentEncoding ?? rawPath
        
        if method == "GET" {
            if path == "/" {
                serveLibraryHTML(connection: connection)
            } else if path.hasPrefix("/download/") {
                let bookIDStr = path.replacingOccurrences(of: "/download/", with: "")
                serveBookFile(bookIDStr, connection: connection)
            } else {
                sendResponse(connection, statusCode: 404, html: "Not Found")
            }
        } else {
            sendResponse(connection, statusCode: 405, html: "Method Not Allowed")
        }
    }
    
    private func serveLibraryHTML(connection: NWConnection) {
        // Fetch all books
        let descriptor = FetchDescriptor<BetaBook>(sortBy: [SortDescriptor(\.dateAdded, order: .reverse)])
        let allBooks = (try? modelContext.fetch(descriptor)) ?? []
        
        var bookListItems = ""
        for book in allBooks {
            bookListItems += """
            <li class="book-item">
                <div class="book-title">\(book.title)</div>
                <div class="book-meta">\(book.contentType.rawValue) • \(book.formattedSize)</div>
                <a class="download-btn" href="/download/\(book.id.uuidString)">Download to Kindle</a>
            </li>
            """
        }
        
        if bookListItems.isEmpty {
            bookListItems = "<p class='no-books'>No books in the library. Import files on your iPhone/iPad first!</p>"
        }
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Inksync Beta Sideload Server</title>
            <style>
                body { font-family: -apple-system, system-ui, sans-serif; background-color: #121212; color: #E0E0E0; margin: 0; padding: 20px; }
                .container { max-width: 600px; margin: 0 auto; background-color: #1E1E1E; padding: 25px; border-radius: 12px; box-shadow: 0 4px 10px rgba(0,0,0,0.3); }
                h1 { font-size: 24px; color: #FFA726; margin-top: 0; text-align: center; }
                p.subtitle { text-align: center; color: #9E9E9E; margin-bottom: 30px; font-size: 14px; }
                ul { list-style: none; padding: 0; margin: 0; }
                .book-item { padding: 15px; border-bottom: 1px solid #2C2C2C; display: flex; flex-direction: column; }
                .book-item:last-child { border-bottom: none; }
                .book-title { font-weight: bold; color: #FFFFFF; font-size: 16px; margin-bottom: 5px; }
                .book-meta { font-size: 12px; color: #B0B0B0; margin-bottom: 10px; }
                .download-btn { background-color: #FFA726; color: #000; text-decoration: none; padding: 8px 12px; border-radius: 6px; font-size: 14px; font-weight: bold; text-align: center; align-self: flex-start; transition: background 0.2s; }
                .download-btn:hover { background-color: #FFB74D; }
                .no-books { text-align: center; color: #9E9E9E; font-style: italic; padding: 20px 0; }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>Inksync Library</h1>
                <p class="subtitle">Download books directly to your Kindle device browser</p>
                <ul>
                    \(bookListItems)
                </ul>
            </div>
        </body>
        </html>
        """
        
        sendResponse(connection, statusCode: 200, html: html)
    }
    
    private func serveBookFile(_ uuidStr: String, connection: NWConnection) {
        guard let id = UUID(uuidString: uuidStr) else {
            sendResponse(connection, statusCode: 400, html: "Invalid Book ID")
            return
        }
        
        let descriptor = FetchDescriptor<BetaBook>(predicate: #Predicate<BetaBook> { $0.id == id })
        guard let book = try? modelContext.fetch(descriptor).first else {
            sendResponse(connection, statusCode: 404, html: "Book not found")
            return
        }
        
        let fileURL = book.resolvedURL
        let fileName = fileURL.lastPathComponent
        
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let mimeType = fileName.pathExtension == "epub" ? "application/epub+zip" : "application/octet-stream"
            
            var header = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: \(mimeType)\r\n"
                + "Content-Length: \(data.count)\r\n"
                + "Content-Disposition: attachment; filename=\"\(fileName)\"\r\n"
                + "Connection: close\r\n\r\n"
            
            connection.send(content: header.data(using: .utf8), completion: .idempotent)
            connection.send(content: data, completion: .contentProcessed({ [weak self] _ in
                self?.closeConnection(connection)
            }))
        } catch {
            sendResponse(connection, statusCode: 500, html: "Internal Server Error: \(error.localizedDescription)")
        }
    }
    
    private func sendResponse(_ connection: NWConnection, statusCode: Int, html: String) {
        let data = html.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(statusCode) OK\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(data.count)\r\n"
            + "Connection: close\r\n\r\n"
        
        var resp = header.data(using: .utf8)!
        resp.append(data)
        
        connection.send(content: resp, completion: .contentProcessed({ [weak self] _ in
            self?.closeConnection(connection)
        }))
    }
    
    private func closeConnection(_ connection: NWConnection) {
        connection.cancel()
        activeConnections = max(0, activeConnections - 1)
    }
    
    // MARK: - IP Address Helper
    
    private func getIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                guard let interface = ptr?.pointee else { break }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                
                if addrFamily == UInt8(AF_INET) {
                    if let cString = interface.ifa_name,
                       let name = String(cString: cString, encoding: .utf8) {
                        
                        if name == "en0" { // en0 is standard WiFi interface on iOS
                            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                            address = String(cString: hostname)
                        }
                    }
                }
                ptr = interface.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
}

// Helper to escape XML special characters
extension String {
    func xmlEscaped() -> String {
        return self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
