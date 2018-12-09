//
// Created by James Sangalli on 8/11/18.
//
import Foundation
import Result
import web3swift
import CryptoSwift

//https://github.com/ethereum/EIPs/blob/master/EIPS/eip-137.md
extension String {
    var nameHash: String {
        var node = Array<UInt8>.init(repeating: 0x0, count: 32)
        if !self.isEmpty {
            node = self.split(separator: ".")
                .map { Array($0.utf8).sha3(.keccak256) }
                .reversed()
                .reduce(node) { return ($0 + $1).sha3(.keccak256) }
        }
        return "0x" + node.toHexString()
    }
}

class GetENSOwnerCoordinator {
    private struct ENSLookupKey: Hashable {
        let name: String
        let server: RPCServer
    }

    private static var resultsCache = [ENSLookupKey:EthereumAddress]()
    private static let DELAY_AFTER_STOP_TYPING_TO_START_RESOLVING_ENS_NAME = TimeInterval(0.5)

    private var toStartResolvingEnsNameTimer: Timer?
    private let config: Config

    init(config: Config) {
        self.config = config
    }

    func getENSOwner(
            for input: String,
            completion: @escaping (Result<EthereumAddress, AnyError>) -> Void
    ) {

        //if already an address, send back the address
        if let ethAddress = EthereumAddress(input) {
            completion(.success(ethAddress))
            return
        }

        //if it does not contain .eth, then it is not a valid ens name
        if !input.contains(".") {
            completion(.failure(AnyError(Web3Error(description: "Invalid ENS Name"))))
            return
        }

        let node = input.lowercased().nameHash
        if let cachedResult = cachedResult(forNode: node) {
            completion(.success(cachedResult))
            return
        }

        guard let webProvider = Web3HttpProvider(config.rpcURL, network: config.server.web3Network) else {
            completion(.failure(AnyError(Web3Error(description: "Error creating web provider for: \(config.rpcURL) + \(config.server.web3Network)"))))
            return
        }

        let web3 = web3swift.web3(provider: webProvider)
        let function = GetENSOwnerEncode()
        let ensRegistrarContract = config.ensRegistrarContract
        guard let contractInstance = web3swift.web3.web3contract(web3: web3, abiString: "[\(function.abi)]", at: ensRegistrarContract, options: web3.options) else {
            completion(.failure(AnyError(Web3Error(description: "Error creating web3swift contract instance to call \(function.name)()"))))
            return
        }

        guard let promise = contractInstance.method(function.name, parameters: [node] as [AnyObject], options: nil) else {
            completion(.failure(AnyError(Web3Error(description: "Error calling \(function.name)() on \(ensRegistrarContract.address)"))))
            return
        }

        promise.callPromise(options: nil).done { result in
            //if null address is returned (as 0) we count it as invalid
            //this is because it is not assigned to an ENS and puts the user in danger of sending funds to null
            if let owner = result["0"] as? EthereumAddress {
                if owner.address == Constants.nullAddress {
                    completion(.failure(AnyError(Web3Error(description: "Null address returned"))))
                } else {
                    //Retain self because it's useful to cache the results even if we don't immediately need it now
                    self.cache(forNode: node, result: owner)
                    completion(.success(owner))
                }
            } else {
                completion(.failure(AnyError(Web3Error(description: "Error extracting result from \(ensRegistrarContract.address).\(function.name)()"))))
            }
        }.catch { error in
            completion(.failure(AnyError(Web3Error(description: "Error extracting result from \(ensRegistrarContract.address).\(function.name)(): \(error)"))))
        }
    }

    func queueGetENSOwner(for input: String, completion: @escaping (Result<EthereumAddress, AnyError>) -> Void) {
        let node = input.lowercased().nameHash
        if let cachedResult = cachedResult(forNode: node) {
            completion(.success(cachedResult))
            return
        }

        toStartResolvingEnsNameTimer?.invalidate()
        toStartResolvingEnsNameTimer = Timer.scheduledTimer(withTimeInterval: GetENSOwnerCoordinator.DELAY_AFTER_STOP_TYPING_TO_START_RESOLVING_ENS_NAME, repeats: false) { _ in
            //Retain self because it's useful to cache the results even if we don't immediately need it now
            self.getENSOwner(for: input) { result in
                completion(result)
            }
        }
    }

    private func cachedResult(forNode node: String) -> EthereumAddress? {
        return GetENSOwnerCoordinator.resultsCache[ENSLookupKey(name: node, server: config.server)]
    }

    private func cache(forNode node: String, result: EthereumAddress) {
        GetENSOwnerCoordinator.resultsCache[ENSLookupKey(name: node, server: config.server)] = result
    }
}
