//
//  Filter.swift
//  FireAlarm
//
//  Created by NobodyNada on 9/24/16.
//  Copyright © 2016 NobodyNada. All rights reserved.
//

import Foundation

class Word {
	let text: String
	let trueProbability: Double
	let falseProbability: Double
	
	init(_ text: String, _ pTrue: Double, _ pFalse: Double) {
		self.text = text
		trueProbability = pTrue
		falseProbability = pFalse
	}
}

class Filter {
	let bot: ChatBot
	let client: Client
	
	let initialProbability: Double
	let words: [String:Word]
	
	var recentlyReportedPosts = [(id: Int, when: Date)]()
	
	init(_ bot: ChatBot) {
		self.bot = bot
		client = bot.room.client
		
		print("Loading filter...")
		
		let data = try! Data(contentsOf: saveDirURL.appendingPathComponent("filter.json"))
		let db = try! JSONSerialization.jsonObject(with: data, options: []) as! [String:Any]
		initialProbability = db["initialProbability"] as! Double
		var words = [String:Word]()
		for (word, probabilites) in db["wordProbabilities"] as! [String:[Double]] {
			words[word] = Word(word, probabilites.first!, probabilites.last!)
		}
		
		self.words = words
	}
	
	var ws: WebSocket!
	
	fileprivate var wsRetries = 0
	fileprivate let wsMaxRetries = 10
	
	private var _running = false
	
	
	var running: Bool {
		return _running
	}
	
	func start() throws {
		_running = true
		
		//let request = URLRequest(url: URL(string: "ws://qa.sockets.stackexchange.com/")!)
		//ws = WebSocket(request: request)
		//ws.eventQueue = bot.room.client.queue
		//ws.delegate = self
		//ws.open()
		ws = try WebSocket("wss://qa.sockets.stackexchange.com/")
		
		ws.onOpen {socket in
			self.webSocketOpen()
		}
		ws.onText {socket, text in
			self.webSocketMessageText(text)
		}
		ws.onBinary {socket, data in
			self.webSocketMessageData(data)
		}
		ws.onClose {socket in
			self.webSocketClose(0, reason: "", wasClean: true)
			self.webSocketEnd(0, reason: "", wasClean: true, error: socket.error)
		}
		ws.onError {socket in
			self.webSocketEnd(0, reason: "", wasClean: true, error: socket.error)
		}
		
		try ws.connect()
	}
	
	func stop() {
		_running = false
		ws?.disconnect()
	}
	
	func webSocketOpen() {
		print("Listening to active questions!")
		let _ = try? ws.write("155-questions-active")
	}
	
	func webSocketClose(_ code: Int, reason: String, wasClean: Bool) {
		//do nothing -- we'll handle this in webSocketEnd
	}
	
	func webSocketError(_ error: NSError) {
		//do nothing -- we'll handle this in webSocketEnd
	}
	
	enum QuestionProcessingError: Error {
		case textNotUTF8(text: String)
		
		case jsonNotDictionary(json: String)
		case jsonParsingError(json: String, error: NSError)
		case noDataObject(json: String)
		case noQuestionID(json: String)
		case noSite(json: String)
	}
	
	func checkPost(_ post: Post) -> Bool {
		var trueProbability = Double(0.263)
		var falseProbability = Double(1 - trueProbability)
		var checkedWords = [String]()
		
		let body = post.body
		
		for postWord in body.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) {
			if postWord.isEmpty {
				continue
			}
			guard let word = words[postWord] else {
				continue
			}
			checkedWords.append(postWord)
			
			let pTrue = word.trueProbability
			let pFalse = word.falseProbability
			
			
			let newTrue = trueProbability * Double(pTrue)
			let newFalse = falseProbability * Double(pFalse)
			if newTrue != 0.0 && newFalse != 0.0 {
				trueProbability = newTrue
				falseProbability = newFalse
			}
		}
		
		return trueProbability * 1e45 > falseProbability
	}
	
	enum ReportResult {
		case notBad	//the post was not bad
		case alreadyReported
		case reported
	}
	
	@discardableResult func checkAndReportPost(_ post: Post) throws -> ReportResult {
		let bad = checkPost(post)
		if bad {
			return reportPost(post)
		}
		else {
			return .notBad
		}
	}
	
	///Reports a post if it has not been recently reported.  Returns either .reported or .alreadyReported.
	func reportPost(_ post: Post) -> ReportResult {
		if let minDate: Date = Calendar(identifier: .gregorian).date(byAdding: DateComponents(hour: -6), to: Date()) {
			recentlyReportedPosts = recentlyReportedPosts.filter {
				$0.when > minDate
			}
		}
		else {
			bot.room.postMessage("Failed to calculate minimum report date!")
		}
		
		if recentlyReportedPosts.contains(where: { $0.id == post.id }) {
			print("Not reporting \(post.id) because it was recently reported.")
			return .alreadyReported
		}
		print("Reporting question \(post.id).")
		
		recentlyReportedPosts.append((id: post.id, when: Date()))
		bot.room.postMessage("[ [FireAlarm-Swift](\(githubLink)) ] " +
			"[tag:\(post.tags.first ?? "tagless")] Potentially bad question: [\(post.title)](//stackoverflow.com/q/\(post.id)) " +
			bot.room.notificationString(tags: post.tags)
		)
		
		return .reported
	}
	
	func webSocketMessageText(_ text: String) {
		do {
			guard let data = text.data(using: .utf8) else {
				throw QuestionProcessingError.textNotUTF8(text: text)
			}
			webSocketMessageData(data)
		} catch {
			handleError(error, "while processing an active question")
		}
	}
	
	func webSocketMessageData(_ data: Data) {
		let string = String(data: data, encoding: .utf8) ?? "<not UTF-8: \(data.base64EncodedString())>"
		do {
			
			do {
				guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String:String] else {
					throw QuestionProcessingError.jsonNotDictionary(json: string)
				}
				
				guard let dataObject = json["data"]?.data(using: .utf8) else {
					throw QuestionProcessingError.noDataObject(json: string)
				}
				
				guard let data = try JSONSerialization.jsonObject(with: dataObject, options: []) as? [String:Any] else {
					throw QuestionProcessingError.noDataObject(json: string)
				}
				
				guard let site = data["apiSiteParameter"] as? String else {
					throw QuestionProcessingError.noSite(json: string)
				}
				
				guard site == "stackoverflow" else {
					return
				}
				
				guard let id = data["id"] as? Int else {
					throw QuestionProcessingError.noQuestionID(json: string)
				}
				
				let post = try bot.room.client.questionWithID(id)
				
				//don't report posts that are more than a day old
				if post.creationDate < post.lastActivityDate - 60 * 60 * 24 {
					return
				}
				
				try checkAndReportPost(post)
			} catch Client.APIError.noItems {
				//do nothing
			} catch let error as Client.APIError {
				throw error
			}
			catch let error as NSError {
				throw QuestionProcessingError.jsonParsingError(json: string, error: error)
			}
		}
		catch {
			handleError(error, "while processing an active question")
		}
	}
	
	private func attemptReconnect() {
		var done = false
		repeat {
			do {
				if wsRetries >= wsMaxRetries {
					bot.room.postMessage(
						"Realtime questions websocket died; failed to reconnect!  Active posts will not be reported until a reboot.  (cc @NobodyNada)"
					)
					return
				}
				wsRetries += 1
				try start()
				done = true
			} catch {
				done = false
			}
		} while !done
	}
	
	func webSocketEnd(_ code: Int, reason: String, wasClean: Bool, error: Error?) {
		if let e = error {
			print("Websocket error:\n\(e)")
		}
		else {
			print("Websocket closed")
		}
		
		if running {
			print("Trying to reconnect...")
			attemptReconnect()
		}
	}
}
