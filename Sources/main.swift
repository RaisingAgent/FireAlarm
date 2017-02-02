//
//  main.swift
//  FireAlarm
//
//  Created by NobodyNada on 8/27/16.
//  Copyright © 2016 NobodyNada. All rights reserved.
//

import Foundation
import Dispatch
import SwiftChatSE
import SwiftStack

let commands: [Command.Type] = [
	CommandSay.self,
	CommandHelp.self, CommandListRunning.self, CommandStop.self, CommandKill.self, CommandUpdate.self, CommandStatus.self,
	CommandCheckPost.self, CommandQuota.self,
	CommandBlacklistUsername.self, CommandGetBlacklistedUsernames.self, CommandUnblacklistUsername.self,
	CommandOptIn.self, CommandOptOut.self, CommandCheckNotification.self,
	CommandCheckPrivileges.self, CommandPrivilege.self, CommandUnprivilege.self,
]

//var apiClient = APIClient(proxyAddress: "127.0.0.1", proxyPort: 8080)
var apiClient = APIClient()

extension ChatUser {
	var notified: Bool {
		get {
			return ((info["notified"] as? Int) ?? 0) == 1 ? true : false
		} set {
			info["notified"] = (newValue ? 1 : 0)
		}
	}
	var notificationTags: [String] {
		get {
			return (info["notificationTags"] as? [String]) ?? []
		} set {
			info["notificationTags"] = newValue
		}
	}
	var notificationReasons: [String] {
		get {
			return (info["notificationReasons"] as? [String]) ?? []
		} set {
			info["notificationReasons"] = newValue
		}
	}
}

extension ChatRoom {
	
	
	func notificationString(tags: [String], reason: Filter.ReportReason) -> String {
		var users = [ChatUser]()
		for user in userDB {
			var shouldNotify = false
			
			if user.notified {
				switch reason {
				case .bayesianFilter:
					if !user.notificationTags.isEmpty {
						for tag in tags {
							if user.notificationTags.contains(tag) {
								shouldNotify = true
							}
						}
					}
					else {
						shouldNotify = true
					}
					
				case .blacklistedUsername:
					if (user.notificationReasons.isEmpty && user.notificationTags.isEmpty)
						|| user.notificationReasons.contains("username") {
						
						shouldNotify = true
					}
					
				case .misleadingLink:
					if (user.notificationReasons.isEmpty && user.notificationTags.isEmpty)
						|| user.notificationReasons.contains("misleadingLink") {
						
						shouldNotify = true
					}
				}
				
			}
			
			if shouldNotify {
				users.append(user)
			}
		}
		
		return users.map { "@" + $0.name.replacingOccurrences(of: " ", with: "") }.joined(separator: " ")
	}
}

extension ChatUser.Privileges {
	static let blacklist = ChatUser.Privileges(rawValue: 1 << 1)
}

ChatUser.Privileges.add(name: "Blacklist", for: .blacklist)


private enum BackgroundTask {
	case handleInput(input: String)
	case shutDown(reboot: Bool, update: Bool)
}

private var backgroundTasks = [BackgroundTask]()
private let backgroundSemaphore = DispatchSemaphore(value: 0)

let saveDirURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".firealarm", isDirectory: true)



fileprivate var listener: ChatListener!

var filter: Filter!

func main() throws {
	print("FireAlarm starting...")
	startTime = Date()
	
	//Save the working directory & change to the chatbot directory.
	let originalWorkingDirectory = FileManager.default.currentDirectoryPath
	
	let saveDirURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".firealarm", isDirectory: true)
	
	if !FileManager.default.fileExists(atPath: saveDirURL.path) {
		try! FileManager.default.createDirectory(at: saveDirURL, withIntermediateDirectories: false, attributes: nil)
	}
	
	saveURL = saveDirURL
	
	let _ = FileManager.default.changeCurrentDirectoryPath(saveDirURL.path)
	
	apiClient.key = "HNA2dbrFtyTZxeHN6rThNg(("
	apiClient.defaultFilter = "withbody"
	
	
	//Log in
	let client = Client(host: .StackOverflow)
	
	let env =  ProcessInfo.processInfo.environment
	
	if !client.loggedIn {
		let email: String
		let password: String
		
		let envEmail = env["ChatBotEmail"]
		let envPassword = env["ChatBotPass"]
		
		if envEmail != nil {
			email = envEmail!
		}
		else {
			print("Email: ", terminator: "")
			email = readLine()!
		}
		
		if envPassword != nil {
			password = envPassword!
		}
		else {
			password = String(validatingUTF8: getpass("Password: "))!
		}
		
		do {
			try client.login(email: email, password: password)
		}
		catch {
			handleError(error, "while logging in")
			exit(EXIT_FAILURE)
		}
	}
	
	
	
	//Join the chat room
	let rooms: [ChatRoom]
	let development: Bool
	if let devString = env["DEVELOPMENT"], let devRoom = Int(devString) {
		rooms = [ChatRoom(client: client, roomID: devRoom)]
		development = true
	}
	else {
		rooms = [
			ChatRoom(client: client, roomID: 111347), //SOBotics
			ChatRoom(client: client, roomID: 68414),  //SOCVR Testing Facility
		]
		
		development = false
	}
	try rooms.forEach {try $0.loadUserDB()}
	
	afterTooManyErrors = {
		print("Too many errors; aborting...")
		abort()
	}
	errorRoom = rooms.first!
	
	
	listener = ChatListener(commands: commands)
	listener.onShutdown { halt(reboot: $0 == .reboot, update: $0 == .update) }
	rooms.forEach {room in room.onMessage { listener.processMessage(room, message: $0, isEdit: $1) } }
	
	try rooms.forEach { try $0.join() }
	
	//Post the startup message
	let startupMessage: String
	
	currentVersion = getCurrentVersion()
	if FileManager.default.fileExists(atPath: "update-failure") {
		startupMessage = "Update failed!"
		try! FileManager.default.removeItem(atPath: "update-failure")
	}
	else if let new = try? loadFile("version-new.txt").replacingOccurrences(of: "\n", with: "") {
		let components = new.components(separatedBy: " ")
		let new = components.first ?? ""
		let newShort = getShortVersion(new)
		let newLink = getVersionLink(new)
		
		let old = currentVersion
		let oldShort = getShortVersion(old)
		let oldLink = getVersionLink(old)
		
		let message = components.count > 1 ? (" (" + components[1..<components.count].joined(separator: " ") + ")") : ""
		
		startupMessage = "Updated from [`\(oldShort)`](\(oldLink)) to [`\(newShort)`](\(newLink))\(message)."
		
		try! new.write(toFile: "version.txt", atomically: true, encoding: .utf8)
		currentVersion = new
		try! FileManager.default.removeItem(atPath: "version-new.txt")
	}
	else {
		startupMessage = "[\(botName)](\(githubLink)) started."
	}
	
	rooms.forEach { $0.postMessage(startupMessage) }
	
	shortVersion = getShortVersion(currentVersion)
	versionLink = getVersionLink(currentVersion)
	
	
	
	//Load the filter
	filter = Filter(rooms)
	try filter.start()
	
	
	
	
	//Run background tasks
	func save() {
		do {
			try rooms.forEach { try $0.saveUserDB() }
		} catch {
			handleError(error, "while saving the user database")
		}
		do {
			try filter.saveUsernameBlacklist()
		} catch {
			handleError(error, "while saving the username blacklist")
		}
		do {
			try filter.saveReports()
		} catch {
			handleError(error, "while saving reports")
		}
	}
	
	func autosaveAndUpdate() {
		var updated = false
		while true {
			//wait one minute
			sleep(60)
			if !updated && !development {
				updated = update(listener, rooms)
			}
			
			save()
		}
	}
	
	DispatchQueue.global().async { autosaveAndUpdate() }
	
	
	func inputMonitor() {
		repeat {
			if let input = readLine() {
				backgroundTasks.append(.handleInput(input: input))
				backgroundSemaphore.signal()
			} else {
				//if EOF is reached,
				return
			}
		} while true
	}
	
	
	DispatchQueue.global().async(execute: inputMonitor)
	
	
	func inputFileMonitor() {
		do {
			let manager = FileManager.default
			let file = "input.txt"
			repeat {
				if manager.fileExists(atPath: file) {
					let input = String(
						data: try Data(contentsOf: saveURL.appendingPathComponent(file)),
						encoding: .utf8
						)!
					
					try manager.removeItem(atPath: file)
					
					backgroundTasks.append(.handleInput(input: input.trimmingCharacters(in: .whitespacesAndNewlines)))
					backgroundSemaphore.signal()
				}
				sleep(1)
			} while true
		} catch {
			handleError(error, "while monitoring input.txt")
		}
	}
	
	
	DispatchQueue.global().async(execute: inputFileMonitor)
	
	
	repeat {
		//wait for a background task
		backgroundSemaphore.wait()
		
		switch backgroundTasks.removeFirst() {
		case .handleInput(let input):
			var messageContent = input
			
			guard let firstComponent = input.components(separatedBy: .whitespaces).first else {
				break
			}
			
			let room: ChatRoom
			if firstComponent.hasPrefix(">") {
				let roomIDStr = firstComponent.substring(
					from: firstComponent.characters.index(after: firstComponent.characters.startIndex)
				)
				guard let roomID = Int(roomIDStr) else {
					print("Invalid room ID.")
					break
				}
				
				guard let roomIndex = rooms.index(where: { roomID == $0.roomID }) else {
					print("I'm not  in that room.")
					break
				}
				
				room = rooms[roomIndex]
				
				messageContent = input.components(separatedBy: .whitespaces).dropFirst().joined(separator: " ")
			} else {
				room = rooms.first!
			}
			
			listener.processMessage(
				room,
				message: ChatMessage(
					room: room,
					user: room.userWithID(0),
					content: messageContent,
					id: nil
				),
				isEdit: false
			)
		case .shutDown(let reboot, let update):
			var shouldReboot = reboot
			
			filter.stop()
			
			//Wait for pending messages to be posted.
			for room in rooms {
				while !room.messageQueue.isEmpty {
					sleep(1)
				}
			}
			while !(filter.ws.state == .disconnected || filter.ws.state == .error) {
				sleep(1)
			}
			
			save()
			
			if update {
				if installUpdate() {
					execv(saveDirURL.appendingPathComponent("firealarm").path, CommandLine.unsafeArgv)
				}
				else {
					shouldReboot = true
				}
			}
			
			rooms.forEach { $0.leave() }
			
			if shouldReboot {
				//Change to the old working directory.
				let _ = FileManager.default.changeCurrentDirectoryPath(originalWorkingDirectory)
				
				//Reload the program binary, which will restart the bot.
				execv(CommandLine.arguments[0], CommandLine.unsafeArgv)
			}
			//If a reboot fails, it will fall through to here & just shutdown instead.
			return
		}
	} while true
}

func halt(reboot: Bool = false, update: Bool = false) {
	backgroundTasks.append(.shutDown(reboot: reboot, update: update))
	backgroundSemaphore.signal()
}




try! main()

