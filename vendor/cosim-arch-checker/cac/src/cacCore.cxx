#include "cacCore.h"
#include <iostream>
#include <sstream>
#include <iomanip>
#include <cstdlib>
#include <fstream>

// CacCore
CacCore::CacCore(threadT tNum):threadNum(tNum){
    record = new Record(threadNum);
    loadCsrCompareMasks();
    for(threadT tid = 0; tid<tNum; tid++){
        RegisterSnapshot regSnpSt(tid);
        registerSnapshot.insert_or_assign(tid, regSnpSt);
        std::vector<Register> ckBuff;
        checkingBuffer.insert_or_assign(tid, ckBuff);
        stepCount.insert_or_assign(tid, 0);
        dutChangeCount.insert_or_assign(tid, 0);
        simChangeCount.insert_or_assign(tid, 0);
        status.insert_or_assign(tid, true);

        InfoCol dutInfoColIns(tid, stepCount.at(tid), "DUT");
        record->addInfoCol(tid, true, dutInfoColIns);
        InfoCol simInfoColIns(tid, stepCount.at(tid), "SIM");
        record->addInfoCol(tid, false, simInfoColIns);
    }
};

std::string CacCore::getHello(){
    return("CacCore has been constructed!");
}

int CacCore::getStep(threadT threadId){
    return(stepCount.at(threadId));
};

// get if mismatch
bool CacCore::getStatus(threadT threadId){
    return(status.at(threadId));
};

void CacCore::resetStatus(threadT threadId){
    status.at(threadId) = true;
};

// Configuration API
void CacCore::configureVlen(unsigned int vlen) {
    cfg_vlen = vlen;
    for(threadT tid = 0; tid<threadNum; tid++){
      registerSnapshot.at(tid).updateSize(cfg_vlen);
    }
}

unsigned int CacCore::getRegisterSize(stateIdT id) {
    if (id >= CAC_STATE_RegV0_ID && id <= CAC_STATE_RegV31_ID) {
      return cfg_vlen;
    } else if (id < (sizeof(supportStatesSize) / sizeof(supportStatesSize[0]))) {
      return supportStatesSize[id];
    }
    return UNIT_BIT_NUM;
}

// Simulator API to update Register
void CacCore::updateRefRegister(threadT threadId, unsigned int typeEncoding, unsigned int typeOffset, unitDataT * data){
    stateIdT id = generateStateId(typeEncoding, typeOffset);
    registerSnapshot.at(threadId).updateValue(id, data);
    Info infoIns(threadId, id, getStateName(id), "SIM", data, getRegisterSize(id));
    record->addInfo(threadId, false, infoIns);
    simChangeCount.at(threadId) = simChangeCount.at(threadId) + 1;
};
void CacCore::updateRefRegister(threadT threadId, stateIdT id, unitDataT * data){
    registerSnapshot.at(threadId).updateValue(id, data);
    Info infoIns(threadId, id, getStateName(id), "SIM", data, getRegisterSize(id));
    record->addInfo(threadId, false, infoIns);
    simChangeCount.at(threadId) = simChangeCount.at(threadId) + 1;
};

void CacCore::updateRefCsr(threadT threadId, uint64_t csr, unitDataT * data){
    updateRefRegister(threadId, generateCsrStateId(csr), data);
};

void CacCore::updateRefMemory(threadT threadId, uint64_t addr, unitDataT * data){
    updateRefRegister(threadId, generateMemoryStateId(addr), data);
};


// Dut API to update Register
void CacCore::updateRegister(threadT threadId, unsigned int typeEncoding, unsigned int typeOffset, unitDataT * data){
    stateIdT id = generateStateId(typeEncoding, typeOffset);
    Info infoIns(threadId, id, getStateName(id), "DUT", data, getRegisterSize(id));
    record->addInfo(threadId, true, infoIns);
    Register reg(threadId, id, getRegisterSize(id), data);
    checkingBuffer.at(threadId).push_back(reg);
    dutChangeCount.at(threadId) = dutChangeCount.at(threadId) + 1;
};
void CacCore::updateRegister(threadT threadId, stateIdT id, unitDataT * data){
    Info infoIns(threadId, id, getStateName(id), "DUT", data, getRegisterSize(id));
    record->addInfo(threadId, true, infoIns);
    Register reg(threadId, id, getRegisterSize(id), data);
    checkingBuffer.at(threadId).push_back(reg);
    dutChangeCount.at(threadId) = dutChangeCount.at(threadId) + 1;
};

void CacCore::updateCsr(threadT threadId, uint64_t csr, unitDataT * data){
    updateRegister(threadId, generateCsrStateId(csr), data);
};

void CacCore::updateMemory(threadT threadId, uint64_t addr, unitDataT * data){
    updateRegister(threadId, generateMemoryStateId(addr), data);
};



bool CacCore::checkRegister(threadT threadId, stateIdT id, unitDataT * data){
    return(registerSnapshot.at(threadId).checkValue(id, data));
};

// make a lock step
void CacCore::step(threadT threadId){
    // print changecount mismatch as warning
    // Updates with same previous values are allowed, so not flagging as error
    // Updates with different values will show up as errors downstream
    if (dutChangeCount.at(threadId) != simChangeCount.at(threadId)) {
      std::cout<<"\nWarning: ChangeCount Mismatch"
               <<" DUT: "<<dutChangeCount.at(threadId)
               <<" SIM: "<<simChangeCount.at(threadId)<<std::endl;
    }
    // use rtl changecount and check against iss snapshot
    std::vector<Register> buffer = checkingBuffer.at(threadId);
    for (std::vector<Register>::iterator it = buffer.begin(); it != buffer.end(); ++it) {
        std::vector<size8BytesT> reg = it->getValue();
        unitDataT *dat = reg.data();
        bool ckRst;
        ckRst = checkRegisterMasked(threadId, it->getRegisterId(), dat);
        status.at(threadId) = status.at(threadId) && ckRst;
    }
    //print out
    if (status.at(threadId) == false){
        std::cout<<"\nRegister Mismatch"<<std::endl;
    }
    std::cout<<"Step: "<<std::dec<<stepCount.at(threadId)<<std::endl;
    InfoCol dutInfoColDebug = record->getInfoColByStep(threadId, true, stepCount.at(threadId));
    InfoCol simInfoColDebug = record->getInfoColByStep(threadId, false, stepCount.at(threadId));
    dutInfoColDebug.outputStates(&simInfoColDebug);

    stepCount.at(threadId) = stepCount.at(threadId) + 1;
    checkingBuffer.at(threadId).clear();
    dutChangeCount.insert_or_assign(threadId, 0);
    simChangeCount.insert_or_assign(threadId, 0);

    InfoCol dutInfoColIns(threadId, stepCount.at(threadId), "DUT");
    record->addInfoCol(threadId, true, dutInfoColIns);
    InfoCol simInfoColIns(threadId, stepCount.at(threadId), "SIM");
    record->addInfoCol(threadId, false, simInfoColIns);
};

// Generate State Id by type encoding and offset
// 0:RT_FIX, 1:RT_FLT, 2:RT_X, 3: RT_PAS
// GPR, FPR, CSR, Vec, PC
stateIdT CacCore::generateStateId(unsigned int typeEncoding, unsigned int typeOffset){
    if (typeEncoding == REGISTER_RT_FIX_ENCODING){
        return(CAC_STATE_RegX0_ID + typeOffset);
    } else if (typeEncoding == REGISTER_RT_FLT_ENCODING) {
        return(CAC_STATE_RegF0_ID + typeOffset);
    } else if (typeEncoding == REGISTER_RT_VEC_ENCODING) {
        return(CAC_STATE_RegV0_ID + typeOffset);
    } else if (typeEncoding == REGISTER_RT_CSR_ENCODING) {
        return generateCsrStateId(typeOffset);
    }else{
        std::cout<<"\nError: Unknown register type encoding"<<std::endl;
        exit(1);
    }

}

stateIdT CacCore::generateCsrStateId(uint64_t csr){
    return CAC_STATE_CSR_BASE_ID + csr;
}

stateIdT CacCore::generateMemoryStateId(uint64_t addr){
    return CAC_STATE_MEM_BASE_ID + addr;
}

bool CacCore::decodeCsrStateId(stateIdT id, uint64_t &csr) const {
    if (id < CAC_STATE_CSR_BASE_ID || id >= CAC_STATE_MEM_BASE_ID) {
        return false;
    }
    csr = id - CAC_STATE_CSR_BASE_ID;
    return true;
}

bool CacCore::checkRegisterMasked(threadT threadId, stateIdT id, unitDataT * data){
    uint64_t csr = 0;
    if (!decodeCsrStateId(id, csr)) {
        return checkRegister(threadId, id, data);
    }
    auto maskIt = csrCompareMasks.find(csr);
    if (maskIt == csrCompareMasks.end()) {
        return checkRegister(threadId, id, data);
    }
    unitDataT mask = maskIt->second;
    if (mask == 0) {
        return true;
    }
    std::vector<unitDataT> refValue;
    try {
        refValue = registerSnapshot.at(threadId).getValue(id);
    } catch (const std::out_of_range&) {
        return false;
    }
    return !refValue.empty() && ((refValue.at(0) & mask) == (data[0] & mask));
}

void CacCore::loadCsrCompareMasks(){
    const char *path = std::getenv("CAC_CSR_MASK_FILE");
    if (path == nullptr || path[0] == '\0') {
        return;
    }

    std::ifstream maskFile(path);
    if (!maskFile.good()) {
        std::cout << "Warning: CAC_CSR_MASK_FILE not readable: " << path << std::endl;
        return;
    }

    std::string line;
    while (std::getline(maskFile, line)) {
        std::string trimmed = line;
        std::size_t comment = trimmed.find('#');
        if (comment != std::string::npos) {
            trimmed = trimmed.substr(0, comment);
        }
        std::stringstream ss(trimmed);
        std::string csrText;
        std::string maskText;
        if (!(ss >> csrText >> maskText)) {
            continue;
        }
        uint64_t csr = std::stoull(csrText, nullptr, 0);
        unitDataT mask = std::stoull(maskText, nullptr, 0);
        csrCompareMasks[csr] = mask;
    }
}

std::string CacCore::getStateName(stateIdT id){
    if (id >= CAC_STATE_MEM_BASE_ID) {
        std::stringstream ss;
        ss << "MEM[0x" << std::hex << (id - CAC_STATE_MEM_BASE_ID) << "]";
        return ss.str();
    }
    if (id >= CAC_STATE_CSR_BASE_ID) {
        std::stringstream ss;
        ss << "CSR[0x" << std::hex << (id - CAC_STATE_CSR_BASE_ID) << "]";
        return ss.str();
    }
    if (id < (sizeof(supportStatesSymbol) / sizeof(supportStatesSymbol[0]))) {
        return supportStatesSymbol[id];
    }
    std::stringstream ss;
    ss << "STATE[0x" << std::hex << id << "]";
    return ss.str();
}
