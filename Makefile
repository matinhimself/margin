.PHONY: server seed demo test mac ios clean
server:
	cd backend && go run ./cmd/library serve
seed:
	cd backend && go run ./cmd/library import -file examples/books.json
demo: seed server
test:
	cd backend && go test -race ./... && go vet ./...
	cd app && swift test
mac:
	xcodebuild -project app/Margin.xcodeproj -scheme Margin -destination 'platform=macOS' -derivedDataPath app/build/mac CODE_SIGNING_ALLOWED=NO build
ios:
	xcodebuild -project app/Margin.xcodeproj -scheme Margin -destination 'generic/platform=iOS Simulator' -derivedDataPath app/build/ios CODE_SIGNING_ALLOWED=NO build
clean:
	rm -rf app/build app/.build
