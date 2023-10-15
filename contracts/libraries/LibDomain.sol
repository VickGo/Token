// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Domain } from "../Domain.sol";
import { IFeatureManager } from "../apps/core/FeatureManager/IFeatureManager.sol";
import { IFeatureRoutes } from "../apps/core/FeatureManager/IFeatureRoutes.sol";

error NoSelectorsGivenToAdd();
error NotContractOwner(address _user, address _contractOwner);
error NoSelectorsProvidedForFeature(address _featureAddress);
error CannotAddSelectorsToZeroAddress(bytes4[] _selectors);
error NoBytecodeAtAddress(address _contractAddress, string _message);
error IncorrectFeatureManagerAction(uint8 _action);
error CannotAddFunctionToFeatureThatAlreadyExists(bytes4 _selector);
error CannotReplaceFunctionsFromFeatureWithZeroAddress(bytes4[] _selectors);
error CannotReplaceImmutableFunction(bytes4 _selector);
error CannotReplaceFunctionWithTheSameFunctionFromTheSameFeature(bytes4 _selector);
error CannotReplaceFunctionThatDoesNotExists(bytes4 _selector);
error RemoveFeatureAddressMustBeZeroAddress(address _featureAddress);
error CannotRemoveFunctionThatDoesNotExist(bytes4 _selector);
error CannotRemoveImmutableFunction(bytes4 _selector);
error InitializationFunctionReverted(address _initializationContractAddress, bytes4 _functionSelector, bytes _calldata);
error NotTokenAdmin(address currentAdminAddress);

library LibDomain {
    bytes32 constant DOMAIN_STORAGE_POSITION = keccak256("domain.standard.storage");
    bytes32 constant DEFAULT_ADMIN_ROLE = keccak256("DEFAULT_ADMIN_ROLE");
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    event OwnershipTransferred(address previousOwner, address _newOwner);
    event AdminshipTransferred(address indexed previousAdmin, address indexed newAdmin);
    event FeatureManagerExecuted(IFeatureManager.Feature[] _features, address _initAddress, bytes4 _functionSelector, bytes _calldata, bool _force);

    
    error FunctionNotFound(bytes4 _functionSelector);

    struct FeatureAddressAndSelectorPosition {
        address featureAddress;
        uint16 selectorPosition;
    }

    struct DomainStorage {
        address parentDomain;
        string name;
        address[] domains;
        mapping(address => uint256) domainIdx;
        mapping(bytes4 => FeatureAddressAndSelectorPosition) featureAddressAndSelectorPosition;
        bytes4[] selectors;
        mapping(address => bool) initializedFeatures;
        mapping(address => bool) pausedFeatures;
        mapping(bytes4 => bool) pausedSelectors;
        address contractOwner;
        address superAdmin;
        mapping(bytes32 => mapping(address => bool)) accessControl;
        mapping(bytes32 => bytes32) roleAdmins; 
        mapping(bytes4 => bytes32) functionRoles;
        mapping(bytes32 => mapping(bytes32 => bytes32)) roles;
        bool paused;
    }


    function enforceIsTokenSuperAdmin() internal view {
        if(msg.sender != domainStorage().superAdmin) {
            revert NotTokenAdmin(domainStorage().superAdmin);
        }        
    }

    function setSuperAdmin(address _newAdmin) internal {
        enforceIsContractOwnerAdmin();
        address previousAdmin = domainStorage().superAdmin;
        domainStorage().superAdmin = _newAdmin;
        domainStorage().accessControl[DEFAULT_ADMIN_ROLE][_newAdmin] = true;   
        domainStorage().accessControl[PAUSER_ROLE][_newAdmin] = true;  
        domainStorage().accessControl[DEFAULT_ADMIN_ROLE][previousAdmin] = false;   
        domainStorage().accessControl[PAUSER_ROLE][previousAdmin] = false;    
        emit AdminshipTransferred(previousAdmin, _newAdmin);
    }

    function domainStorage() internal pure returns (DomainStorage storage ds) {
        bytes32 position = DOMAIN_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }    

    function domainSecureStorage(bytes32 storageKey) internal pure returns (DomainStorage storage ds) {
        bytes32 position = storageKey;
        assembly {
            ds.slot := position
        }
    }

    function setContractOwner(address _newOwner) internal {
        enforceIsContractOwnerAdmin();
        
        address previousOwner = domainStorage().contractOwner;
        domainStorage().contractOwner = _newOwner;
        domainStorage().accessControl[DEFAULT_ADMIN_ROLE][_newOwner] = true;   
        domainStorage().accessControl[PAUSER_ROLE][_newOwner] = true;  
        domainStorage().accessControl[DEFAULT_ADMIN_ROLE][previousOwner] = false;   
        domainStorage().accessControl[PAUSER_ROLE][previousOwner] = false;          
        emit OwnershipTransferred(previousOwner, _newOwner);
    }

    function contractOwner() internal view returns (address contractOwner_) {
        contractOwner_ = domainStorage().contractOwner;
    }

    function contractSuperAdmin() internal view returns (address contractAdmin_) {
        contractAdmin_ = domainStorage().superAdmin;
    }   

    function enforceIsContractOwnerAdmin() internal view {
        if(address(0) != domainStorage().contractOwner  && address(0) != domainStorage().superAdmin && msg.sender != domainStorage().contractOwner && msg.sender != domainStorage().superAdmin) {
            revert NotContractOwner(msg.sender, domainStorage().contractOwner);
        }        
    } 

    function enforceIsContractOwner() internal view {
        if(address(0) != domainStorage().contractOwner  && address(0) != domainStorage().superAdmin &&msg.sender != domainStorage().contractOwner) {
            revert NotContractOwner(msg.sender, domainStorage().contractOwner);
        }        
    }     

    function featureManager(
        IFeatureManager.Feature[] memory _features,
        address _initAddress,
        bytes4 _functionSelector,        
        bytes memory _calldata,
        bool _force     
    ) internal {
        for (uint256 featureIndex; featureIndex < _features.length; featureIndex++) {
            bytes4[] memory functionSelectors = _features[featureIndex].functionSelectors;
            address FeatureAddress = _features[featureIndex].featureAddress;

            if(functionSelectors.length == 0) {
                revert NoSelectorsProvidedForFeature(FeatureAddress);
            }

            IFeatureManager.FeatureManagerAction action = _features[featureIndex].action;
            if (action == IFeatureManager.FeatureManagerAction.Add) {
                addFunctions(FeatureAddress, functionSelectors);
            } else if (action == IFeatureManager.FeatureManagerAction.Replace) {
                replaceFunctions(FeatureAddress, functionSelectors);
            } else if (action == IFeatureManager.FeatureManagerAction.Remove) {
                removeFunctions(FeatureAddress, functionSelectors);
            } else {
                revert IncorrectFeatureManagerAction(uint8(action));
            }
        }

        emit FeatureManagerExecuted(_features, _initAddress, _functionSelector, _calldata, _force);
        initializeFeatureManager(_initAddress, _functionSelector, _calldata, _force);
    }

    function addFunctions(address _FeatureAddress, bytes4[] memory _functionSelectors) internal {  
        if(_FeatureAddress == address(0)) {
            revert CannotAddSelectorsToZeroAddress(_functionSelectors);
        }
        
        uint16 selectorCount = uint16(domainStorage().selectors.length);                
        enforceHasContractCode(_FeatureAddress, "LibFeatureManager: Add feature has no code");
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFeatureAddress = domainStorage().featureAddressAndSelectorPosition[selector].featureAddress;
            if(oldFeatureAddress != address(0)) {
                continue;
            }            
            domainStorage().featureAddressAndSelectorPosition[selector] = FeatureAddressAndSelectorPosition(_FeatureAddress, selectorCount);
            domainStorage().selectors.push(selector);
            selectorCount++;
        }
    }

    function replaceFunctions(address _FeatureAddress, bytes4[] memory _functionSelectors) internal {       
        
        if(_FeatureAddress == address(0)) {
            revert CannotReplaceFunctionsFromFeatureWithZeroAddress(_functionSelectors);
        }
        enforceHasContractCode(_FeatureAddress, "LibFeatureManager: Replace feature has no code");
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFeatureAddress = domainStorage().featureAddressAndSelectorPosition[selector].featureAddress;
            if(oldFeatureAddress == address(this)) {
                revert CannotReplaceImmutableFunction(selector);
            }
            if(oldFeatureAddress == _FeatureAddress) {
                revert CannotReplaceFunctionWithTheSameFunctionFromTheSameFeature(selector);
            }
            if(oldFeatureAddress == address(0)) {
                revert CannotReplaceFunctionThatDoesNotExists(selector);
            }
            domainStorage().featureAddressAndSelectorPosition[selector].featureAddress = _FeatureAddress;
        }
    }

    function removeFunctions(address _FeatureAddress, bytes4[] memory _functionSelectors) internal {        
        
        uint256 selectorCount = domainStorage().selectors.length;
        if(_FeatureAddress == address(0)) {
            revert RemoveFeatureAddressMustBeZeroAddress(_FeatureAddress);
        }        
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            FeatureAddressAndSelectorPosition memory oldFeatureAddressAndSelectorPosition = domainStorage().featureAddressAndSelectorPosition[selector];
            if(oldFeatureAddressAndSelectorPosition.featureAddress == address(0)) {
                revert CannotRemoveFunctionThatDoesNotExist(selector);
            }        
            if(oldFeatureAddressAndSelectorPosition.featureAddress == address(this)) {
                revert CannotRemoveImmutableFunction(selector);
            }
            selectorCount--;
            if (oldFeatureAddressAndSelectorPosition.selectorPosition != selectorCount) {
                bytes4 lastSelector = domainStorage().selectors[selectorCount];
                domainStorage().selectors[oldFeatureAddressAndSelectorPosition.selectorPosition] = lastSelector;
                domainStorage().featureAddressAndSelectorPosition[lastSelector].selectorPosition = oldFeatureAddressAndSelectorPosition.selectorPosition;
            }
            domainStorage().selectors.pop();
            delete domainStorage().featureAddressAndSelectorPosition[selector];
        }
    }

    function initializeFeatureManager(
        address _initAddress,
        bytes4 _functionSelector,        
        bytes memory _calldata,
        bool _force
    ) internal {
        
        if (_initAddress != address(0) && (_force || !domainStorage().initializedFeatures[_initAddress])) {
            enforceHasContractCode(_initAddress, "LibFeatureManager: _init address has no code");        
            (bool success, bytes memory error) = _initAddress.delegatecall(_calldata);
            domainStorage().initializedFeatures[_initAddress] = success;
            //handleInitializationOutcome(success, error, _initAddress, _functionSelector, _calldata, _force);
        } else if (_functionSelector != bytes4(0)){
            address feature = domainStorage().featureAddressAndSelectorPosition[_functionSelector].featureAddress;
            if((_force || !domainStorage().initializedFeatures[feature])){
                if(feature == address(0)) {
                    revert FunctionNotFound(_functionSelector);
                }
                domainStorage().initializedFeatures[feature] = true;
                assembly {
                            calldatacopy(0, 0, calldatasize())
                            let result := delegatecall(gas(), feature, 0, calldatasize(), 0, 0)
                            returndatacopy(0, 0, returndatasize())
                            switch result
                                case 0 {
                                    revert(0, returndatasize())
                                }
                                default {
                                    return(0, returndatasize())
                                }
                        }
            
            }
        }
    }


    function enforceHasContractCode(address _contract, string memory _errorMessage) internal view {
        uint256 contractSize;
        assembly {
            contractSize := extcodesize(_contract)
        }
        if(contractSize == 0) {
            revert NoBytecodeAtAddress(_contract, _errorMessage);
        }        
    }
}
