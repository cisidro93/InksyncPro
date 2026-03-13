import Foundation

class XHTMLGenerator {
    static func generateSVGWrappedXHTML(imageName: String, width: Int, height: Int) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xmlns:xlink="http://www.w3.org/1999/xlink">
        <head>
            <meta charset="UTF-8"/>
            <meta name="viewport" content="width=\(width), height=\(height)"/>
            <title>\(imageName)</title>
            <style type="text/css">
                @page { margin: 0; padding: 0; }
                html, body {
                    margin: 0;
                    padding: 0;
                    width: 100vw;
                    height: 100vh;
                    background-color: black;
                    overflow: hidden;
                }
                svg {
                    display: block;
                    margin: 0;
                    padding: 0;
                    width: 100vw;
                    height: 100vh;
                }
            </style>
        </head>
        <body>
            <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" 
                 width="100vw" height="100vh" viewBox="0 0 \(width) \(height)" preserveAspectRatio="xMidYMid meet">
                <image width="\(width)" height="\(height)" xlink:href="../images/\(imageName)"/>
            </svg>
        </body>
        </html>
        """
    }
}
