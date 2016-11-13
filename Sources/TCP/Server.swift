//
//  Server.swift
//  Edge
//
//  Created by Tyler Fleming Cloutier on 4/30/16.
//
//

import Dispatch
import Reflex
import POSIX
import POSIXExtensions
import IOStream
#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

public final class Server {
    
    private static let defaultReuseAddress = true
    
    private let fd: SocketFileDescriptor
    private let listeningSource: DispatchSourceRead
    
    public convenience init(reuseAddress: Bool = defaultReuseAddress) throws {
        let fd = try SocketFileDescriptor(socketType: SocketType.stream, addressFamily: AddressFamily.inet)
        try self.init(fd: fd, reuseAddress: reuseAddress)
    }
    
    public init(fd: SocketFileDescriptor, reuseAddress: Bool = defaultReuseAddress) throws {
        self.fd = fd
        if reuseAddress {
            // Set SO_REUSEADDR
            var reuseAddr = 1
            let error = setsockopt(self.fd.rawValue, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int>.stride))
            if error != 0 {
                throw SystemError(errorNumber: errno)!
            }
        }
        
        self.listeningSource = DispatchSource.makeReadSource(fileDescriptor: self.fd.rawValue, queue: .main)
        
        // Close the socket when the source is canceled.
        listeningSource.setCancelHandler { [fd = self.fd] in
            fd.close()
        }
    }
    
    public func bind(host: String, port: Port) throws {
        var addrInfoPointer: UnsafeMutablePointer<addrinfo>? = nil
        
        var hints = systemCreateAddressInfo(
            ai_flags: 0,
            ai_family: fd.addressFamily.rawValue,
            ai_socktype: POSIXExtensions.SOCK_STREAM,
            ai_protocol: POSIXExtensions.IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        
        let ret = getaddrinfo(host, String(port), &hints, &addrInfoPointer)
        if let systemError = SystemError(errorNumber: ret) {
            throw systemError
        }
        
        let addressInfo = addrInfoPointer!.pointee
        
        let bindRet = systemBind(fd.rawValue, addressInfo.ai_addr, socklen_t(MemoryLayout<sockaddr>.stride))
        freeaddrinfo(addrInfoPointer)
        
        if bindRet != 0 {
            throw SystemError(errorNumber: errno)!
        }
    }
    
    public func listen(backlog: Int = 32) -> ColdSignal<Socket, SystemError> {
        return ColdSignal { [listeningSource = self.listeningSource, fd = self.fd] observer in
            let ret = systemListen(fd.rawValue, Int32(backlog))
            if ret != 0 {
                observer.sendFailed(SystemError(errorNumber: errno)!)
                return nil
            }
            listeningSource.setEventHandler {
                                
                var socketAddress = sockaddr()
                var sockLen = socklen_t(POSIXExtensions.SOCK_MAXADDRLEN)
                
                // Accept connections
                let numPendingConnections: UInt = listeningSource.data
                for _ in 0..<numPendingConnections {
                    let ret = systemAccept(fd.rawValue, &socketAddress, &sockLen)
                    if ret == StandardFileDescriptor.invalid.rawValue {
                        observer.sendFailed(SystemError(errorNumber: errno)!)
                    }
                    let clientFileDescriptor = SocketFileDescriptor(
                        rawValue: ret,
                        socketType: SocketType.stream,
                        addressFamily: fd.addressFamily,
                        blocking: false
                    )
                    
                    do {
                        // Create the client connection socket
                        let clientConnection = try Socket(fd: clientFileDescriptor)
                        observer.sendNext(clientConnection)
                    } catch {
                        let systemError = error as! SystemError
                        observer.sendFailed(systemError)
                        return
                    }
                }
            }
            if #available(OSX 10.12, *) {
                listeningSource.activate()
            } else {
                listeningSource.resume()
            }
            return ActionDisposable {
                listeningSource.cancel()
            }
        }
    }
}
