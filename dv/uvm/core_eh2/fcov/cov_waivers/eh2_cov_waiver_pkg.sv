// SPDX-License-Identifier: Apache-2.0
// EH2 Coverage Waiver Package
//
// Provides a mechanism to load and query coverage waivers at runtime.
// Waivers document coverage points that are known-unreachable or
// architecturally blocked, so they can be excluded from signoff metrics.
//
// Usage:
//   import eh2_cov_waiver_pkg::*;
//   load_waivers("path/to/cov_waivers/");
//   if (is_waived("uarch_cg.stall_cross")) ...

package eh2_cov_waiver_pkg;

  // =========================================================================
  // Waiver data structure
  // =========================================================================
  typedef struct {
    string name;             // Human-readable description
    string coverage_point;   // covergroup.coverpoint_or_cross
    string reason;           // Technical justification
    string author;           // Approver
    string date;             // YYYY-MM-DD
    string ticket;           // Tracking issue (may be empty)
    string status;           // "active" | "superseded" | "withdrawn"
  } cov_waiver_t;

  // =========================================================================
  // Global waiver store
  // =========================================================================
  // Associative array keyed by coverage_point string for O(1) lookup.
  cov_waiver_t waivers[string];

  // =========================================================================
  // load_waivers
  //
  // Reads all .yaml files in the given directory and populates the
  // waivers associative array.  Only active waivers are loaded.
  //
  // The YAML parser is intentionally simple: it reads line-by-line
  // looking for "key: value" pairs inside a "waiver:" block.
  // =========================================================================
  function automatic void load_waivers(string dir);
    int       dir_handle;
    string    filename;
    string    filepath;
    int       code;

    dir_handle = $fopen({dir, "/"}, "r");  // placeholder - see note below

    // SystemVerilog cannot list directory contents portably.
    // Instead, call load_waiver_file() for each known waiver file,
    // or use the wrapper task load_all_waivers() which is driven
    // by a filelist.
    //
    // For a practical approach, we provide load_waiver_file() that
    // reads a single YAML file.  The testbench calls it once per
    // waiver file, or uses the helper task below with a filelist.
    $display("[cov_waiver] load_waivers: use load_waiver_file() for each file");
  endfunction

  // =========================================================================
  // load_waiver_file
  //
  // Parses a single YAML waiver file and adds it to the store if active.
  // =========================================================================
  function automatic void load_waiver_file(string filepath);
    int         fd;
    string      line;
    bit         in_waiver;
    cov_waiver_t w;
    string      key, val;
    int         colon_pos;

    fd = $fopen(filepath, "r");
    if (fd == 0) begin
      $display("[cov_waiver] WARNING: cannot open %0s", filepath);
      return;
    end

    // Initialize struct
    w.name           = "";
    w.coverage_point = "";
    w.reason         = "";
    w.author         = "";
    w.date           = "";
    w.ticket         = "";
    w.status         = "active";

    in_waiver = 0;

    while (!$feof(fd)) begin
      void'($fgets(line, fd));

      // Strip leading/trailing whitespace
      line = str_trim(line);

      // Skip comments and blank lines
      if (line.len() == 0 || line[0] == "#")
        continue;

      // Detect start of waiver block
      if (line == "waiver:") begin
        in_waiver = 1;
        continue;
      end

      // Parse key: value lines inside waiver block
      if (in_waiver) begin
        colon_pos = str_find(line, ":");
        if (colon_pos > 0) begin
          key = str_trim(line.substr(0, colon_pos - 1));
          val = str_trim(line.substr(colon_pos + 1, line.len() - 1));

          // Strip surrounding quotes
          if (val.len() >= 2 && val[0] == "\"" && val[val.len()-1] == "\"")
            val = val.substr(1, val.len() - 2);

          // Strip trailing ">" (YAML folded scalar indicator)
          if (val == ">")
            val = "";

          case (key)
            "name":           w.name           = val;
            "coverage_point": w.coverage_point = val;
            "reason":         w.reason         = val;
            "author":         w.author         = val;
            "date":           w.date           = val;
            "ticket":         w.ticket         = val;
            "status":         w.status         = val;
            default: ; // ignore unknown keys
          endcase
        end
      end
    end

    $fclose(fd);

    // Store if valid and active
    if (w.coverage_point.len() > 0 && w.status == "active") begin
      waivers[w.coverage_point] = w;
      $display("[cov_waiver] Loaded waiver: %0s -> %0s",
               w.coverage_point, w.name);
    end
  endfunction

  // =========================================================================
  // load_waiver_filelist
  //
  // Reads a text file containing one waiver YAML path per line.
  // Blank lines and lines starting with '#' are ignored.
  // =========================================================================
  function automatic void load_waiver_filelist(string filelist_path);
    int      fd;
    string   line;
    string   trimmed;

    fd = $fopen(filelist_path, "r");
    if (fd == 0) begin
      $display("[cov_waiver] WARNING: cannot open filelist %0s", filelist_path);
      return;
    end

    while (!$feof(fd)) begin
      void'($fgets(line, fd));
      trimmed = str_trim(line);
      if (trimmed.len() > 0 && trimmed[0] != "#")
        load_waiver_file(trimmed);
    end

    $fclose(fd);
  endfunction

  // =========================================================================
  // is_waived
  //
  // Returns 1 if the given coverage point has an active waiver.
  // =========================================================================
  function automatic bit is_waived(string coverage_point);
    return waivers.exists(coverage_point);
  endfunction

  // =========================================================================
  // get_waiver
  //
  // Returns the waiver struct for a given coverage point.
  // Returns an empty struct if not found.
  // =========================================================================
  function automatic cov_waiver_t get_waiver(string coverage_point);
    cov_waiver_t empty;
    if (waivers.exists(coverage_point))
      return waivers[coverage_point];
    empty.name = "";
    empty.coverage_point = "";
    empty.reason = "";
    empty.author = "";
    empty.date = "";
    empty.ticket = "";
    empty.status = "";
    return empty;
  endfunction

  // =========================================================================
  // print_waivers
  //
  // Diagnostics: print all loaded waivers.
  // =========================================================================
  function automatic void print_waivers();
    string key;
    cov_waiver_t w;
    $display("[cov_waiver] === Loaded Waivers ===");
    if (waivers.num() == 0) begin
      $display("[cov_waiver]   (none)");
      return;
    end
    foreach (waivers[key]) begin
      w = waivers[key];
      $display("[cov_waiver]   %0s", w.coverage_point);
      $display("[cov_waiver]     name:   %0s", w.name);
      $display("[cov_waiver]     reason: %0s", w.reason);
      $display("[cov_waiver]     author: %0s  date: %0s", w.author, w.date);
    end
    $display("[cov_waiver] === End Waivers ===");
  endfunction

  // =========================================================================
  // String helpers (SystemVerilog has no built-in string manipulation)
  // =========================================================================

  // Trim leading and trailing whitespace
  function automatic string str_trim(string s);
    int start, end_;
    if (s.len() == 0) return s;

    start = 0;
    while (start < s.len() && (s[start] == " " || s[start] == "\t" ||
           s[start] == "\n" || s[start] == "\r"))
      start++;

    end_ = s.len() - 1;
    while (end_ >= start && (s[end_] == " " || s[end_] == "\t" ||
           s[end_] == "\n" || s[end_] == "\r"))
      end_--;

    if (start > end_) return "";
    return s.substr(start, end_);
  endfunction

  // Find first occurrence of character ch in string s.
  // Returns -1 if not found.
  function automatic int str_find(string s, string ch);
    for (int i = 0; i < s.len(); i++) begin
      if (s[i] == ch[0]) return i;
    end
    return -1;
  endfunction

endpackage
