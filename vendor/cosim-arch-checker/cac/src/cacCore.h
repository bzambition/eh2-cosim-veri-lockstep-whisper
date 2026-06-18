#ifndef CAC_CORE_H
#define CAC_CORE_H

#include <map>
#include <string>
#include <vector>
#include <unordered_map>
#include "caclib.h"
#include "register.h"
#include "info.h"

class CacCore
{
    public:
        // Constructor
        CacCore(threadT tNum);
        // Hello World function to make unit test work
        std::string getHello();
        // Configuration API
        void configureVlen(unsigned int vlen);
        // Dut API to update Register
        void updateRegister(threadT threadId, unsigned int typeEncoding, unsigned int typeOffset, unitDataT * data);
        void updateRegister(threadT threadId, stateIdT id, unitDataT * data);
        void updateCsr(threadT threadId, uint64_t csr, unitDataT * data);
        void updateMemory(threadT threadId, uint64_t addr, unitDataT * data);
        // Simulator API to update Register
        void updateRefRegister(threadT threadId, unsigned int typeEncoding, unsigned int typeOffset, unitDataT * data);
        void updateRefRegister(threadT threadId, stateIdT id, unitDataT * data);
        void updateRefCsr(threadT threadId, uint64_t csr, unitDataT * data);
        void updateRefMemory(threadT threadId, uint64_t addr, unitDataT * data);
        // Make a lock step
        void step(threadT threadId);
        // Api to get which step it is
        int getStep(threadT threadId);
        // Api to get the check result
        bool getStatus(threadT threadId);
        void resetStatus(threadT threadId);

        // TODO: fuzz mask
        // void updateRegister(threadT threadId, stateIdT id, unitDataT * data, fuzzMaskT fuzzMask);
        //void updateMem(threadT threadId);
    private:
        threadT threadNum;
        unsigned int cfg_vlen = VEC_128;
        Record *record;
        std::unordered_map<threadT, bool> status;
        std::unordered_map<threadT, int> stepCount;
        std::unordered_map<threadT, int> dutChangeCount;
        std::unordered_map<threadT, int> simChangeCount;
        std::unordered_map<threadT, RegisterSnapshot> registerSnapshot;
        std::unordered_map<threadT, std::vector<Register>> checkingBuffer;
        std::unordered_map<uint64_t, unitDataT> csrCompareMasks;
        stateIdT generateStateId(unsigned int typeEncoding, unsigned int typeOffset);
        stateIdT generateCsrStateId(uint64_t csr);
        stateIdT generateMemoryStateId(uint64_t addr);
        bool decodeCsrStateId(stateIdT id, uint64_t &csr) const;
        bool checkRegisterMasked(threadT threadId, stateIdT id, unitDataT * data);
        void loadCsrCompareMasks();
        std::string getStateName(stateIdT id);
        bool checkRegister(threadT threadId, stateIdT id, unitDataT * data);
        unsigned int getRegisterSize(stateIdT id);
};

#endif
