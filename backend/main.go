package main

import (
	"bufio"
	"bytes"
	"fmt"
	"log"
	"net"
	"net/url"
	"strings"
)

func main() {
	listener, err := net.Listen("tcp", "0.0.0.0:8000")
	if err != nil {
		log.Fatalf("Failed to bind to port 8000: %v", err)
	}
	log.Println("Native Go HRS Backend listening on 0.0.0.0:8000")

	for {
		conn, err := listener.Accept()
		if err != nil {
			continue
		}
		// Handle keep-alive connections concurrently
		go handleConnection(conn)
	}
}

func handleConnection(conn net.Conn) {
	defer conn.Close()
	reader := bufio.NewReader(conn)

	for {
		// Read the HTTP request line
		requestLine, err := reader.ReadString('\n')
		if err != nil || requestLine == "" {
			return
		}

		// Parse headers to look for the Transfer_Encoding trap
		isChunked := false
		path := strings.Split(requestLine, " ")[1]

		for {
			headerLine, err := reader.ReadString('\n')
			if err != nil || headerLine == "\r\n" {
				break
			}
			upper := strings.ToUpper(strings.TrimSpace(headerLine))
			if strings.Contains(upper, "TRANSFER_ENCODING: CHUNKED") ||
			   strings.Contains(upper, "TRANSFER-ENCODING: CHUNKED") {
				isChunked = true
			}
		}

		// THE NATIVE VULNERABILITY:
		// If TE is present, we read until the 0\r\n\r\n terminator and STOP,
		// completely ignoring the Content-Length. This leaves the smuggled bytes in the socket.
		if isChunked {
			readChunkedBody(reader)
		}

		// Route the request and send the response
		if strings.HasPrefix(path, "/reflect") {
			q := ""
			if parts := strings.Split(path, "?q="); len(parts) > 1 {
				q = parts[1]
			}
			// URL-decode the query parameter so the reflected payload
			// appears as raw HTML (e.g. <script>) instead of %3Cscript%3E.
			if decoded, err := url.QueryUnescape(q); err == nil {
				q = decoded
			}
			sendResponse(conn, "text/html", fmt.Sprintf("<html><body>%s</body></html>\n", q))
		} else if strings.HasPrefix(path, "/js/app.js") {
			sendResponse(conn, "application/javascript", "// Legitimate application script\nconsole.log('App loaded.');\n")
		} else {
			sendResponse(conn, "text/plain", "HRS Native Go Backend: Online\n")
		}
	}
}

// readChunkedBody reads from the socket until it hits the chunked terminator
func readChunkedBody(reader *bufio.Reader) {
	terminator := []byte("0\r\n\r\n")
	var buffer []byte
	for {
		b, err := reader.ReadByte()
		if err != nil {
			break
		}
		buffer = append(buffer, b)
		if bytes.HasSuffix(buffer, terminator) {
			break
		}
	}
}

func sendResponse(conn net.Conn, contentType, body string) {
	response := fmt.Sprintf("HTTP/1.1 200 OK\r\n"+
		"Server: Go-Native-HRS\r\n"+
		"Content-Type: %s\r\n"+
		"Content-Length: %d\r\n"+
		"Connection: keep-alive\r\n\r\n%s", contentType, len(body), body)
	conn.Write([]byte(response))
}