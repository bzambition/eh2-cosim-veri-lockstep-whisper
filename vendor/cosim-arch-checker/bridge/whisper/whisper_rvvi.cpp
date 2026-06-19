// Licensed under the Apache License, Version 2.0, see ../../LICENSE.TT for details
//
// RVVI-API facade for cosim-arch-checker.  The SystemVerilog scoreboard stages
// DUT retire state through the standard rvviDut*/rvviRef* entry points here;
// this file keeps the generic comparison state and drives Whisper as an
// out-of-process reference model over the existing socket client.

#include "rvviApi.h"

#include "whisper_client.h"

#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <set>
#include <map>
#include <sstream>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

constexpr unsigned kMaxHarts = 8;
constexpr unsigned kGprCount = 32;
constexpr unsigned kConnectTimeoutMs = 5000;
constexpr uint64_t kConfigWhisperPath = 1;
constexpr uint64_t kConfigWhisperJson = 2;
constexpr uint64_t kConfigWhisperServerFile = 3;
constexpr uint64_t kNetMip = 1;
constexpr uint64_t kNetDebugMode = 2;
constexpr uint32_t kCsrMip = 0x344;
constexpr char kResourceGpr = 'r';
constexpr char kResourceCsr = 'c';
constexpr char kResourceMemory = 'm';
constexpr char kResourcePc = 'p';

struct HartState {
  uint64_t pc = 0;
  uint64_t insn = 0;
  std::array<uint64_t, kGprCount> gprs{};
  uint32_t gprsWritten = 0;
  std::map<uint32_t, uint64_t> csrs;
  std::map<uint64_t, uint8_t> memory;
};

struct RvviState {
  bool initialized = false;
  std::string whisperPath;
  std::string whisperJson;
  std::string serverFile;
  std::array<HartState, kMaxHarts> refHarts;
  std::array<HartState, kMaxHarts> dutHarts;
  std::array<std::set<uint32_t>, kMaxHarts> csrCompareDisabled;
  std::array<std::map<uint32_t, uint64_t>, kMaxHarts> csrCompareMasks;
  std::map<uint64_t, uint32_t> netGroups;
  std::map<std::pair<uint32_t, uint64_t>, uint64_t> nets;
  std::string loadedCsrMaskFile;
  std::array<uint64_t, RVVI_METRIC_FATALS + 1> metrics{};
  std::string lastError;
};

RvviState state;

bool validHart(uint32_t hartId)
{
  if (hartId < kMaxHarts)
    return true;
  state.lastError = "invalid hart id " + std::to_string(hartId);
  state.metrics[RVVI_METRIC_ERRORS]++;
  return false;
}

const char *getenvNonEmpty(const char *name)
{
  const char *value = std::getenv(name);
  return (value && *value) ? value : nullptr;
}

std::string shellQuote(const std::string &text)
{
  std::string out = "'";
  for (char ch : text) {
    if (ch == '\'')
      out += "'\\''";
    else
      out += ch;
  }
  out += "'";
  return out;
}

void setError(const std::string &message)
{
  state.lastError = message;
  state.metrics[RVVI_METRIC_ERRORS]++;
  std::cerr << "RVVI Whisper error: " << message << "\n";
}

std::string defaultServerFile()
{
  std::ostringstream os;
  os << "/tmp/whisper_rvvi_" << getpid();
  return os.str();
}

bool connectWhisperServer(const std::string &serverFile)
{
  const auto start = std::chrono::steady_clock::now();
  while (true) {
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    if (whisperConnect(serverFile.c_str()) >= 0)
      return true;

    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start).count();
    if (elapsed > kConnectTimeoutMs)
      return false;
  }
}

std::string resolveWhisperPath()
{
  // Preserve the historical priority: simulator environment, RVVI-specific
  // environment, then the value staged through rvviRefConfigSetString().
  if (const char *path = getenvNonEmpty("WHISPER_PATH"))
    return path;
  if (const char *path = getenvNonEmpty("WHISPER_RVVI_WHISPER_PATH"))
    return path;
  return state.whisperPath;
}

std::string resolveWhisperJson()
{
  // JSON selection is owned by the harness/config side; the checker itself
  // stays path-agnostic and only consumes the resolved value.
  if (const char *path = getenvNonEmpty("WHISPER_RVVI_JSON_PATH"))
    return path;
  if (const char *path = getenvNonEmpty("WHISPER_JSON_PATH"))
    return path;
  return state.whisperJson;
}

void applyChange(uint32_t hartId, uint32_t resource, uint64_t addr, uint64_t value,
                 uint32_t flags)
{
  HartState &hart = state.refHarts[hartId];
  switch (resource) {
    case kResourceGpr:
      if (addr < kGprCount) {
        hart.gprs[addr] = value;
        hart.gprsWritten |= (1u << addr);
      }
      break;
    case kResourceCsr:
      hart.csrs[static_cast<uint32_t>(addr)] = value;
      break;
    case kResourceMemory: {
      const unsigned size = flags & 0xffu;
      const unsigned bytes = (size >= 1 && size <= 8) ? size : 8;
      for (unsigned i = 0; i < bytes; ++i)
        hart.memory[addr + i] = static_cast<uint8_t>((value >> (8 * i)) & 0xffu);
      break;
    }
    default:
      break;
  }
}

bool peekResource(uint32_t hartId, char resource, uint64_t addr, uint64_t &value)
{
  bool valid = false;
  if (!whisperPeek(hartId, resource, addr, value, valid)) {
    setError("whisper peek command failed");
    return false;
  }
  if (!valid) {
    setError("whisper peek returned invalid resource");
    return false;
  }
  return true;
}

void loadCsrMasks()
{
  const char *path = getenvNonEmpty("CAC_CSR_MASK_FILE");
  if (!path || state.loadedCsrMaskFile == path)
    return;
  for (auto &hartMasks : state.csrCompareMasks)
    hartMasks.clear();
  state.loadedCsrMaskFile = path;
  std::ifstream file(path);
  if (!file.good()) {
    setError(std::string("CAC_CSR_MASK_FILE not readable: ") + path);
    return;
  }
  std::string line;
  while (std::getline(file, line)) {
    std::size_t comment = line.find('#');
    if (comment != std::string::npos)
      line = line.substr(0, comment);
    std::stringstream ss(line);
    std::string csrText;
    std::string maskText;
    if (!(ss >> csrText >> maskText))
      continue;
    const uint32_t csr = static_cast<uint32_t>(std::stoull(csrText, nullptr, 0));
    const uint64_t mask = std::stoull(maskText, nullptr, 0);
    for (auto &hartMasks : state.csrCompareMasks)
      hartMasks[csr] = mask;
  }
}

uint64_t csrMask(uint32_t hartId, uint32_t csrIndex)
{
  loadCsrMasks();
  const auto found = state.csrCompareMasks[hartId].find(csrIndex);
  return found == state.csrCompareMasks[hartId].end() ? ~uint64_t{0} : found->second;
}

bool compareValue(const char *kind, uint32_t hartId, uint64_t index,
                  uint64_t dut, uint64_t ref, uint64_t mask = ~uint64_t{0})
{
  state.metrics[RVVI_METRIC_MISMATCHES] += ((dut & mask) != (ref & mask)) ? 1 : 0;
  if ((dut & mask) == (ref & mask)) {
    return true;
  }
  std::ostringstream os;
  os << kind << " mismatch hart=" << hartId << " index=0x" << std::hex << index
     << " dut=0x" << dut << " ref=0x" << ref << " mask=0x" << mask;
  setError(os.str());
  return false;
}

uint64_t packMemory(const std::map<uint64_t, uint8_t> &memory, uint64_t address,
                    uint32_t bytes)
{
  uint64_t value = 0;
  for (uint32_t i = 0; i < bytes && i < 8; ++i) {
    const auto found = memory.find(address + i);
    if (found != memory.end())
      value |= uint64_t(found->second) << (8 * i);
  }
  return value;
}

void clearDutStaged(uint32_t hartId)
{
  state.dutHarts[hartId].gprsWritten = 0;
  state.dutHarts[hartId].csrs.clear();
  state.dutHarts[hartId].memory.clear();
}

}  // namespace

extern "C" bool_t rvviVersionCheck(uint32_t version)
{
  return version == RVVI_API_VERSION ? RVVI_TRUE : RVVI_FALSE;
}

extern "C" bool_t rvviRefInit(const char *programPath)
{
  const std::string configuredWhisperPath = state.whisperPath;
  const std::string configuredWhisperJson = state.whisperJson;
  const std::string configuredServerFile = state.serverFile;
  state = RvviState{};
  state.whisperPath = configuredWhisperPath;
  state.whisperJson = configuredWhisperJson;
  state.serverFile = getenvNonEmpty("WHISPER_RVVI_SERVER_FILE")
                         ? getenvNonEmpty("WHISPER_RVVI_SERVER_FILE")
                         : (!configuredServerFile.empty() ? configuredServerFile
                                                          : defaultServerFile());
  loadCsrMasks();

  if (!programPath || !*programPath) {
    setError("rvviRefInit requires an ELF program path");
    return RVVI_FALSE;
  }

  const std::string whisperPath = resolveWhisperPath();
  const std::string whisperJson = resolveWhisperJson();
  if (whisperPath.empty()) {
    setError("whisper binary path is unset; set WHISPER_PATH or rvviRefConfigSetString(1, path)");
    return RVVI_FALSE;
  }
  if (whisperJson.empty()) {
    setError("whisper JSON path is unset; set WHISPER_RVVI_JSON_PATH or rvviRefConfigSetString(2, path)");
    return RVVI_FALSE;
  }

  const std::string logFile = state.serverFile + ".log";
  const std::string cmdLogFile = state.serverFile + ".cmd.log";

  std::ostringstream cmd;
  if (const char *ld = getenvNonEmpty("WHISPER_LD_LIBRARY_PATH"))
    cmd << "LD_LIBRARY_PATH=" << shellQuote(ld) << ":${LD_LIBRARY_PATH:-} ";
  cmd << shellQuote(whisperPath) << " " << shellQuote(programPath)
      << " --configfile " << shellQuote(whisperJson)
      << " --logfile " << shellQuote(logFile)
      << " --commandlog " << shellQuote(cmdLogFile)
      << " --server " << shellQuote(state.serverFile)
      << " &";

  if (std::system(cmd.str().c_str()) != 0) {
    setError("failed to launch whisper server");
    return RVVI_FALSE;
  }
  if (!connectWhisperServer(state.serverFile)) {
    setError("timed out connecting to whisper server file " + state.serverFile);
    return RVVI_FALSE;
  }

  state.initialized = true;
  state.lastError.clear();
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefPcSet(uint32_t hartId, uint64_t address)
{
  if (!validHart(hartId))
    return RVVI_FALSE;
  if (state.initialized) {
    bool valid = false;
    if (!whisperPoke(hartId, kResourcePc, 0, address, valid)) {
      setError("whisper PC poke command failed");
      return RVVI_FALSE;
    }
    if (!valid) {
      setError("whisper PC poke returned invalid");
      return RVVI_FALSE;
    }
  }
  state.refHarts[hartId].pc = address;
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefShutdown(void)
{
  const bool ok = whisperQuit();
  state.initialized = false;
  if (!ok) {
    setError("whisper quit command failed");
    return RVVI_FALSE;
  }
  state.lastError.clear();
  return RVVI_TRUE;
}

// Optional RVVI-API hooks that are not used by the scalar lockstep path are
// implemented as inert stubs so the shared object still conforms to rvviApi.h.
extern "C" bool_t rvviRefCsrSetVolatile(uint32_t, uint32_t)
{
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefMemorySetVolatile(uint64_t, uint64_t)
{
  return RVVI_TRUE;
}

extern "C" uint64_t rvviRefNetIndexGet(const char *name)
{
  if (!name)
    return RVVI_INVALID_INDEX;
  if (std::strcmp(name, "mip") == 0)
    return kNetMip;
  if (std::strcmp(name, "debug_mode") == 0)
    return kNetDebugMode;
  return RVVI_INVALID_INDEX;
}

extern "C" uint8_t rvviRefVrGet(uint32_t, uint32_t, uint32_t)
{
  return 0;
}

extern "C" void rvviDutVrSet(uint32_t, uint32_t, uint32_t, uint8_t) {}
extern "C" void rvviDutFprSet(uint32_t, uint32_t, uint64_t) {}
extern "C" void rvviDutGprSet(uint32_t hartId, uint32_t gprIndex, uint64_t value)
{
  if (!validHart(hartId) || gprIndex >= kGprCount)
    return;
  state.dutHarts[hartId].gprs[gprIndex] = value;
  state.dutHarts[hartId].gprsWritten |= (1u << gprIndex);
}

extern "C" void rvviDutCsrSet(uint32_t hartId, uint32_t csrIndex, uint64_t value)
{
  if (!validHart(hartId))
    return;
  state.dutHarts[hartId].csrs[csrIndex] = value;
}
extern "C" void rvviRefNetGroupSet(uint64_t netIndex, uint32_t group)
{
  if (group >= kMaxHarts) {
    setError("invalid net group hart id " + std::to_string(group));
    return;
  }
  state.netGroups[netIndex] = group;
}

extern "C" void rvviRefNetSet(uint64_t netIndex, uint64_t value, uint64_t)
{
  uint32_t hartId = 0;
  const auto group = state.netGroups.find(netIndex);
  if (group != state.netGroups.end())
    hartId = group->second;
  if (!validHart(hartId))
    return;

  const auto key = std::make_pair(hartId, netIndex);
  const uint64_t oldValue = state.nets.count(key) ? state.nets[key] : 0;
  state.nets[key] = value;

  if (netIndex == kNetMip) {
    state.refHarts[hartId].csrs[kCsrMip] = value;
    if (!state.initialized)
      return;
    bool valid = false;
    if (!whisperPoke(hartId, kResourceCsr, kCsrMip, value, valid))
      setError("whisper mip net poke command failed");
    else if (!valid)
      setError("whisper mip net poke returned invalid");
    return;
  }

  if (netIndex == kNetDebugMode) {
    if (oldValue == value)
      return;
    if (!state.initialized)
      return;
    bool valid = false;
    if (value) {
      if (!whisperEnterDebug(hartId, true, valid))
        setError("whisper enter-debug command failed");
      else if (!valid)
        setError("whisper enter-debug returned invalid");
    } else {
      if (!whisperExitDebug(hartId, valid))
        setError("whisper exit-debug command failed");
      else if (!valid)
        setError("whisper exit-debug returned invalid");
    }
    return;
  }

  bool valid = false;
  if (!state.initialized)
    return;
  if (!whisperPoke(hartId, kResourceCsr, netIndex, value, valid))
    setError("whisper net poke command failed");
  else if (!valid)
    setError("whisper net poke returned invalid");
}

extern "C" uint64_t rvviRefNetGet(uint64_t netIndex)
{
  uint32_t hartId = 0;
  const auto group = state.netGroups.find(netIndex);
  if (group != state.netGroups.end())
    hartId = group->second;
  const auto key = std::make_pair(hartId, netIndex);
  const auto found = state.nets.find(key);
  if (found != state.nets.end())
    return found->second;
  if (netIndex == kNetMip)
    return rvviRefCsrGet(hartId, kCsrMip);
  return 0;
}

extern "C" void rvviDutRetire(uint32_t hartId, uint64_t dutPc,
                               uint64_t dutInsBin, bool_t)
{
  if (!validHart(hartId))
    return;
  state.dutHarts[hartId].pc = dutPc;
  state.dutHarts[hartId].insn = dutInsBin;
}

extern "C" void rvviDutTrap(uint32_t hartId, uint64_t dutPc, uint64_t dutInsBin)
{
  rvviDutRetire(hartId, dutPc, dutInsBin, RVVI_FALSE);
}
extern "C" void rvviRefReservationInvalidate(uint32_t) {}

extern "C" bool_t rvviRefEventStep(uint32_t hartId)
{
  if (!state.initialized) {
    setError("rvviRefEventStep called before rvviRefInit");
    return RVVI_FALSE;
  }
  if (!validHart(hartId))
    return RVVI_FALSE;

  HartState &hart = state.refHarts[hartId];
  hart.gprsWritten = 0;

  uint64_t pc = 0;
  uint32_t instruction = 0;
  unsigned changeCount = 0;
  char buffer[128] = {};
  uint32_t privMode = 0;
  uint32_t fpFlags = 0;
  bool hasTrap = false;
  if (!whisperStep(hartId, state.metrics[RVVI_METRIC_CYCLES],
                   state.metrics[RVVI_METRIC_RETIRES], pc, instruction,
                   changeCount, buffer, sizeof(buffer), privMode, fpFlags,
                   hasTrap)) {
    setError("whisper step command failed");
    return RVVI_FALSE;
  }

  hart.pc = pc;
  hart.insn = instruction;
  state.metrics[RVVI_METRIC_RETIRES]++;
  state.metrics[RVVI_METRIC_CYCLES]++;
  if (hasTrap)
    state.metrics[RVVI_METRIC_TRAPS]++;

  for (unsigned i = 0; i < changeCount; ++i) {
    uint32_t resource = 0;
    uint64_t addr = 0;
    uint64_t value = 0;
    uint32_t flags = 0;
    bool valid = false;
    if (!whisperChangeEx(hartId, resource, addr, value, flags, valid)) {
      setError("whisper change command failed");
      return RVVI_FALSE;
    }
    if (!valid) {
      setError("whisper change returned invalid");
      return RVVI_FALSE;
    }
    applyChange(hartId, resource, addr, value, flags);
  }

  state.lastError.clear();
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefGprsCompare(uint32_t hartId)
{
  if (!validHart(hartId))
    return RVVI_FALSE;
  state.metrics[RVVI_METRIC_COMPARISONS_GPR]++;
  for (uint32_t i = 1; i < kGprCount; ++i) {
    if (!compareValue("GPR", hartId, i, state.dutHarts[hartId].gprs[i],
                      state.refHarts[hartId].gprs[i]))
      return RVVI_FALSE;
  }
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefGprsCompareWritten(uint32_t hartId, bool_t ignoreX0)
{
  if (!validHart(hartId))
    return RVVI_FALSE;
  state.metrics[RVVI_METRIC_COMPARISONS_GPR]++;
  const uint32_t dutWritten = state.dutHarts[hartId].gprsWritten;
  const uint32_t compareWritten = dutWritten;
  bool ok = true;
  for (uint32_t i = 0; i < kGprCount; ++i) {
    if (ignoreX0 && i == 0)
      continue;
    if (compareWritten & (1u << i)) {
      if (!compareValue("GPR", hartId, i, state.dutHarts[hartId].gprs[i],
                        state.refHarts[hartId].gprs[i]))
        ok = false;
    }
  }
  state.dutHarts[hartId].gprsWritten = 0;
  state.refHarts[hartId].gprsWritten = 0;
  return ok ? RVVI_TRUE : RVVI_FALSE;
}

extern "C" bool_t rvviRefInsBinCompare(uint32_t hartId)
{
  if (!validHart(hartId))
    return RVVI_FALSE;
  state.metrics[RVVI_METRIC_COMPARISONS_INSBIN]++;
  return compareValue("INSN", hartId, 0, state.dutHarts[hartId].insn,
                      state.refHarts[hartId].insn) ? RVVI_TRUE : RVVI_FALSE;
}

extern "C" bool_t rvviRefPcCompare(uint32_t hartId)
{
  if (!validHart(hartId))
    return RVVI_FALSE;
  state.metrics[RVVI_METRIC_COMPARISONS_PC]++;
  return compareValue("PC", hartId, 0, state.dutHarts[hartId].pc,
                      state.refHarts[hartId].pc) ? RVVI_TRUE : RVVI_FALSE;
}

extern "C" bool_t rvviRefCsrCompare(uint32_t hartId, uint32_t csrIndex)
{
  if (!validHart(hartId))
    return RVVI_FALSE;
  if (state.csrCompareDisabled[hartId].count(csrIndex))
    return RVVI_TRUE;
  const uint64_t mask = csrMask(hartId, csrIndex);
  if (mask == 0)
    return RVVI_TRUE;
  state.metrics[RVVI_METRIC_COMPARISONS_CSR]++;
  return compareValue("CSR", hartId, csrIndex,
                      state.dutHarts[hartId].csrs[csrIndex],
                      state.refHarts[hartId].csrs[csrIndex], mask)
             ? RVVI_TRUE
             : RVVI_FALSE;
}

extern "C" void rvviRefCsrCompareEnable(uint32_t hartId, uint32_t csrIndex,
                                         bool_t enableState)
{
  if (!validHart(hartId))
    return;
  if (enableState)
    state.csrCompareDisabled[hartId].erase(csrIndex);
  else
    state.csrCompareDisabled[hartId].insert(csrIndex);
}

extern "C" void rvviRefCsrCompareMask(uint32_t hartId, uint32_t csrIndex,
                                       uint64_t mask)
{
  if (!validHart(hartId))
    return;
  state.csrCompareMasks[hartId][csrIndex] = mask;
}

extern "C" bool_t rvviRefCsrsCompare(uint32_t hartId)
{
  if (!validHart(hartId))
    return RVVI_FALSE;
  bool ok = true;
  for (const auto &csr : state.dutHarts[hartId].csrs)
    ok = (rvviRefCsrCompare(hartId, csr.first) == RVVI_TRUE) && ok;
  for (const auto &mem : state.dutHarts[hartId].memory) {
    const uint64_t dut = mem.second;
    const uint64_t ref = packMemory(state.refHarts[hartId].memory, mem.first, 1);
    if (!compareValue("MEM", hartId, mem.first, dut, ref, 0xff))
      ok = false;
  }
  clearDutStaged(hartId);
  return ok ? RVVI_TRUE : RVVI_FALSE;
}
extern "C" bool_t rvviRefVrsCompare(uint32_t) { return RVVI_TRUE; }
extern "C" bool_t rvviRefFprsCompare(uint32_t) { return RVVI_TRUE; }

extern "C" void rvviRefGprSet(uint32_t hartId, uint32_t gprIndex, uint64_t gprValue)
{
  if (!validHart(hartId) || gprIndex >= kGprCount)
    return;
  state.refHarts[hartId].gprs[gprIndex] = gprValue;
  if (state.initialized) {
    bool valid = false;
    if (!whisperPoke(hartId, kResourceGpr, gprIndex, gprValue, valid))
      setError("whisper GPR poke command failed");
  }
}

extern "C" uint64_t rvviRefGprGet(uint32_t hartId, uint32_t gprIndex)
{
  if (!validHart(hartId) || gprIndex >= kGprCount)
    return 0;
  if (gprIndex == 0)
    return 0;
  uint64_t value = state.refHarts[hartId].gprs[gprIndex];
  if (value == 0 && state.initialized)
    (void)peekResource(hartId, kResourceGpr, gprIndex, value);
  state.refHarts[hartId].gprs[gprIndex] = value;
  return value;
}

extern "C" uint32_t rvviRefGprsWrittenGet(uint32_t hartId)
{
  if (!validHart(hartId))
    return 0;
  return state.refHarts[hartId].gprsWritten;
}

extern "C" uint64_t rvviRefPcGet(uint32_t hartId)
{
  if (!validHart(hartId))
    return 0;
  return state.refHarts[hartId].pc;
}

extern "C" uint64_t rvviRefCsrGet(uint32_t hartId, uint32_t csrIndex)
{
  if (!validHart(hartId))
    return 0;
  const auto found = state.refHarts[hartId].csrs.find(csrIndex);
  if (found != state.refHarts[hartId].csrs.end())
    return found->second;
  uint64_t value = 0;
  if (state.initialized && peekResource(hartId, kResourceCsr, csrIndex, value))
    state.refHarts[hartId].csrs[csrIndex] = value;
  return value;
}

extern "C" uint64_t rvviRefInsBinGet(uint32_t hartId)
{
  if (!validHart(hartId))
    return 0;
  return state.refHarts[hartId].insn;
}

extern "C" void rvviRefFprSet(uint32_t, uint32_t, uint64_t) {}
extern "C" uint64_t rvviRefFprGet(uint32_t, uint32_t) { return 0; }
extern "C" void rvviDutBusWrite(uint32_t hartId, uint64_t address,
                                 uint64_t value, uint64_t byteEnableMask)
{
  if (!validHart(hartId))
    return;
  for (uint32_t i = 0; i < 8; ++i) {
    if (byteEnableMask & (1ull << i))
      state.dutHarts[hartId].memory[address + i] =
          static_cast<uint8_t>((value >> (8 * i)) & 0xffu);
  }
}

extern "C" void rvviRefMemoryWrite(uint32_t hartId, uint64_t address,
                                    uint64_t data, uint32_t size)
{
  if (!validHart(hartId))
    return;
  if (state.initialized) {
    bool valid = false;
    if (!whisperPoke(hartId, kResourceMemory, address, data, valid))
      setError("whisper memory poke command failed");
  }
  for (uint32_t i = 0; i < size && i < 8; ++i)
    state.refHarts[hartId].memory[address + i] =
        static_cast<uint8_t>((data >> (8 * i)) & 0xffu);
}

extern "C" uint64_t rvviRefMemoryRead(uint32_t hartId, uint64_t address,
                                      uint32_t size)
{
  if (!validHart(hartId))
    return 0;
  uint64_t value = 0;
  bool haveAllBytes = true;
  for (uint32_t i = 0; i < size && i < 8; ++i) {
    const auto found = state.refHarts[hartId].memory.find(address + i);
    if (found == state.refHarts[hartId].memory.end()) {
      haveAllBytes = false;
      break;
    }
    value |= uint64_t(found->second) << (8 * i);
  }
  if (!haveAllBytes && state.initialized)
    (void)peekResource(hartId, kResourceMemory, address, value);
  return value;
}

extern "C" const char *rvviDasmInsBin(uint32_t, uint64_t, uint64_t)
{
  return "";
}

extern "C" const char *rvviRefCsrName(uint32_t, uint32_t)
{
  return "";
}

extern "C" const char *rvviRefGprName(uint32_t, uint32_t gprIndex)
{
  static const char *names[kGprCount] = {
      "x0",  "x1",  "x2",  "x3",  "x4",  "x5",  "x6",  "x7",
      "x8",  "x9",  "x10", "x11", "x12", "x13", "x14", "x15",
      "x16", "x17", "x18", "x19", "x20", "x21", "x22", "x23",
      "x24", "x25", "x26", "x27", "x28", "x29", "x30", "x31"};
  return gprIndex < kGprCount ? names[gprIndex] : "";
}

extern "C" bool_t rvviRefCsrPresent(uint32_t, uint32_t) { return RVVI_TRUE; }
extern "C" bool_t rvviRefFprsPresent(uint32_t) { return RVVI_FALSE; }
extern "C" bool_t rvviRefVrsPresent(uint32_t) { return RVVI_FALSE; }
extern "C" const char *rvviRefFprName(uint32_t, uint32_t) { return ""; }
extern "C" const char *rvviRefVrName(uint32_t, uint32_t) { return ""; }

extern "C" const char *rvviErrorGet(void)
{
  return state.lastError.c_str();
}

extern "C" uint64_t rvviRefMetricGet(rvviMetricE metric)
{
  if (metric < RVVI_METRIC_RETIRES || metric > RVVI_METRIC_FATALS)
    return 0;
  return state.metrics[metric];
}

extern "C" void rvviRefCsrSet(uint32_t hartId, uint32_t csrIndex, uint64_t value)
{
  if (!validHart(hartId))
    return;
  state.refHarts[hartId].csrs[csrIndex] = value;
  if (state.initialized) {
    bool valid = false;
    if (!whisperPoke(hartId, kResourceCsr, csrIndex, value, valid))
      setError("whisper CSR poke command failed");
  }
}

extern "C" void rvviRefStateDump(uint32_t hartId)
{
  if (!validHart(hartId))
    return;
  std::cout << "RVVI ref hart " << hartId << " pc=0x" << std::hex
            << state.refHarts[hartId].pc << " insn=0x"
            << state.refHarts[hartId].insn << std::dec << "\n";
}

extern "C" bool_t rvviRefProgramLoad(const char *)
{
  return RVVI_FALSE;
}

extern "C" bool_t rvviRefCsrSetVolatileMask(uint32_t, uint32_t, uint64_t)
{
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefCsrSetOneWayCompare(uint32_t, uint32_t, bool_t)
{
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefCsrSetOneWayCompareMask(uint32_t, uint32_t, uint64_t)
{
  return RVVI_TRUE;
}

extern "C" void rvviDutCycleCountSet(uint64_t cycleCount)
{
  state.metrics[RVVI_METRIC_CYCLES] = cycleCount;
}

extern "C" bool_t rvviRefConfigSetInt(uint64_t, uint64_t)
{
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefConfigSetString(uint64_t configParam, const char *value)
{
  if (!value)
    return RVVI_FALSE;
  switch (configParam) {
    case kConfigWhisperPath:
      state.whisperPath = value;
      return RVVI_TRUE;
    case kConfigWhisperJson:
      state.whisperJson = value;
      return RVVI_TRUE;
    case kConfigWhisperServerFile:
      state.serverFile = value;
      return RVVI_TRUE;
    default:
      break;
  }
  return RVVI_TRUE;
}

extern "C" uint32_t rvviRefCsrIndex(uint32_t, const char *)
{
  return RVVI_INVALID_INDEX;
}

extern "C" bool_t rvviRefMemorySetPrivilege(uint64_t, uint64_t, uint32_t)
{
  return RVVI_TRUE;
}

extern "C" void rvviRefVrSet(uint32_t, uint32_t, uint32_t, uint8_t) {}
extern "C" uint64_t rvviRefConnIndexGet(const char *) { return RVVI_INVALID_INDEX; }
extern "C" bool_t rvviRefConnSetEmpty(uint64_t) { return RVVI_TRUE; }
extern "C" bool_t rvviRefConnSetFull(uint64_t) { return RVVI_TRUE; }
extern "C" bool_t rvviRefConnData(uint64_t, uint32_t, uint64_t, bool_t)
{
  return RVVI_TRUE;
}
extern "C" void rvviRefNetCancel(uint64_t) {}
