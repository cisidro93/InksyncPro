import Foundation

class XHTMLGenerator {
    static func generateSVGWrappedXHTML(imageName: String, width: Int, height: Int, isFixedLayout: Bool = true) -> String {
        let viewport = isFixedLayout 
            ? "<meta name=\"viewport\" content=\"width=\(width), height=\(height)\"/>"
            : "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\"/>"
            
        let header = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xmlns:xlink="http://www.w3.org/1999/xlink">
        <head>
            <meta charset="UTF-8"/>
            \(viewport)
            <title>\(imageName)</title>
            <link rel="stylesheet" type="text/css" href="../style.css"/>
        """
        
        let style = """
            <style type="text/css">
                @page { margin: 0; padding: 0; }
                html, body {
                    margin: 0;
                    padding: 0;
                    width: 100%;
                    height: 100%;
                    background-color: black;
                }
                svg {
                    display: block;
                    margin: 0;
                    padding: 0;
                    width: 100%;
                    height: 100%;
                }
            </style>
        </head>
        """
        
        let body = """
        <body>
            <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" 
                 width="100%" height="100%" viewBox="0 0 \(width) \(height)" preserveAspectRatio="xMidYMid meet">
                <image width="\(width)" height="\(height)" xlink:href="../images/\(imageName)"/>
            </svg>
        </body>
        </html>
        """
        
        return header + "\n" + style + "\n" + body
    }
}
