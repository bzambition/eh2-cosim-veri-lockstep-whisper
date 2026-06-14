#  NOTE NOTE NOTE NOTE NOTE NOTE NOTE NOTE NOTE NOTE NOTE NOTE NOTE NOTE NOTE NOTE
#  This is an automatically generated file by ybz on Fri Apr 24 16:22:19 CST 2026
# 
#  cmd:    veer -target=default -set=build_axi4 
# 
# To use this in a perf script, use 'require $RV_ROOT/configs/config.pl'
# Reference the hash via $config{name}..


%config = (
            'icache' => {
                          'icache_banks_way' => 2,
                          'icache_bank_lo' => 3,
                          'icache_num_beats' => 8,
                          'icache_tag_bypass_enable' => '1',
                          'icache_tag_depth' => 128,
                          'icache_size' => 32,
                          'icache_scnd_last' => 6,
                          'icache_tag_lo' => 13,
                          'icache_data_index_lo' => 4,
                          'icache_tag_num_bypass_width' => 2,
                          'icache_ln_sz' => 64,
                          'icache_num_lines_bank' => '64',
                          'icache_bank_width' => 8,
                          'icache_beat_addr_hi' => 5,
                          'icache_num_bypass_width' => 3,
                          'icache_beat_bits' => 3,
                          'icache_tag_num_bypass' => '2',
                          'icache_tag_index_lo' => '6',
                          'icache_data_cell' => 'ram_512x71',
                          'icache_2banks' => '1',
                          'icache_num_lines' => 512,
                          'icache_waypack' => '1',
                          'icache_enable' => 1,
                          'icache_num_bypass' => '4',
                          'icache_index_hi' => 12,
                          'icache_bank_bits' => 1,
                          'icache_tag_cell' => 'ram_128x25',
                          'icache_status_bits' => 3,
                          'icache_data_depth' => '512',
                          'icache_bank_hi' => 3,
                          'icache_num_lines_way' => '128',
                          'icache_ecc' => '1',
                          'icache_fdata_width' => 71,
                          'icache_num_ways' => 4,
                          'icache_bypass_enable' => '1',
                          'icache_data_width' => 64
                        },
            'config_key' => '32\'hdeadbeef',
            'triggers' => [
                            {
                              'mask' => [
                                          '0x081818c7',
                                          '0xffffffff',
                                          '0x00000000'
                                        ],
                              'poke_mask' => [
                                               '0x081818c7',
                                               '0xffffffff',
                                               '0x00000000'
                                             ],
                              'reset' => [
                                           '0x23e00000',
                                           '0x00000000',
                                           '0x00000000'
                                         ]
                            },
                            {
                              'mask' => [
                                          '0x081810c7',
                                          '0xffffffff',
                                          '0x00000000'
                                        ],
                              'poke_mask' => [
                                               '0x081810c7',
                                               '0xffffffff',
                                               '0x00000000'
                                             ],
                              'reset' => [
                                           '0x23e00000',
                                           '0x00000000',
                                           '0x00000000'
                                         ]
                            },
                            {
                              'mask' => [
                                          '0x081818c7',
                                          '0xffffffff',
                                          '0x00000000'
                                        ],
                              'reset' => [
                                           '0x23e00000',
                                           '0x00000000',
                                           '0x00000000'
                                         ],
                              'poke_mask' => [
                                               '0x081818c7',
                                               '0xffffffff',
                                               '0x00000000'
                                             ]
                            },
                            {
                              'reset' => [
                                           '0x23e00000',
                                           '0x00000000',
                                           '0x00000000'
                                         ],
                              'poke_mask' => [
                                               '0x081810c7',
                                               '0xffffffff',
                                               '0x00000000'
                                             ],
                              'mask' => [
                                          '0x081810c7',
                                          '0xffffffff',
                                          '0x00000000'
                                        ]
                            }
                          ],
            'bht' => {
                       'bht_ghr_pad2' => 'fghr[3:0],2\'b0',
                       'bht_ghr_range' => '6:0',
                       'bht_size' => 512,
                       'bht_ghr_size' => 7,
                       'bht_ghr_hash_1' => '',
                       'bht_addr_lo' => '3',
                       'bht_addr_hi' => 9,
                       'bht_ghr_pad' => 'fghr[2:0],3\'b0',
                       'bht_array_depth' => 128,
                       'bht_hash_string' => 0
                     },
            'pic' => {
                       'pic_mpiccfg_count' => 1,
                       'pic_total_int' => 127,
                       'pic_meie_mask' => '0x1',
                       'pic_meigwclr_count' => 127,
                       'pic_total_int_plus1' => 128,
                       'pic_region' => '0xf',
                       'pic_meipl_offset' => '0x0000',
                       'pic_meitp_count' => 4,
                       'pic_meip_count' => 4,
                       'pic_mpiccfg_mask' => '0x1',
                       'pic_mpiccfg_offset' => '0x3000',
                       'pic_meie_count' => 127,
                       'pic_meipl_mask' => '0xf',
                       'pic_meigwclr_mask' => '0x0',
                       'pic_meip_mask' => '0x0',
                       'pic_meigwctrl_mask' => '0x3',
                       'pic_base_addr' => '0xf00c0000',
                       'pic_meigwctrl_count' => 127,
                       'pic_bits' => 15,
                       'pic_meitp_mask' => '0x0',
                       'pic_meigwclr_offset' => '0x5000',
                       'pic_meidels_mask' => '0x1',
                       'pic_2cycle' => '1',
                       'pic_meidels_count' => 127,
                       'pic_meip_offset' => '0x1000',
                       'pic_offset' => '0xc0000',
                       'pic_size' => 32,
                       'pic_meie_offset' => '0x2000',
                       'pic_int_words' => 4,
                       'pic_meitp_offset' => '0x1800',
                       'pic_meipl_count' => 127,
                       'pic_meigwctrl_offset' => '0x4000'
                     },
            'reset_vec' => '0x80000000',
            'iccm' => {
                        'iccm_rows' => '4096',
                        'iccm_bank_hi' => 3,
                        'iccm_num_banks' => '4',
                        'iccm_region' => '0xe',
                        'iccm_bank_bits' => 2,
                        'iccm_num_banks_4' => '',
                        'iccm_offset' => '0xe000000',
                        'iccm_index_bits' => 12,
                        'iccm_enable' => 1,
                        'iccm_bank_index_lo' => 4,
                        'iccm_reserved' => '0x1000',
                        'iccm_sadr' => '0xee000000',
                        'iccm_size' => 64,
                        'iccm_size_64' => '',
                        'iccm_bits' => 16,
                        'iccm_data_cell' => 'ram_4096x39',
                        'iccm_eadr' => '0xee00ffff'
                      },
            'memmap' => {
                          'unused_region0' => '0x70000000',
                          'unused_region6' => '0x10000000',
                          'external_data_1' => '0xb0000000',
                          'debug_sb_mem' => '0xa0580000',
                          'unused_region4' => '0x30000000',
                          'external_mem_hole' => '0x90000000',
                          'unused_region5' => '0x20000000',
                          'unused_region1' => '0x60000000',
                          'unused_region3' => '0x40000000',
                          'unused_region2' => '0x50000000',
                          'serialio' => '0xd0580000',
                          'consoleio' => '0xd0580000',
                          'external_data' => '0xc0580000',
                          'unused_region7' => '0x00000000'
                        },
            'dccm' => {
                        'dccm_bank_bits' => 3,
                        'dccm_width_bits' => 2,
                        'dccm_num_banks' => '8',
                        'dccm_num_banks_8' => '',
                        'dccm_rows' => '2048',
                        'dccm_byte_width' => '4',
                        'dccm_region' => '0xf',
                        'dccm_fdata_width' => 39,
                        'dccm_size_64' => '',
                        'dccm_data_width' => 32,
                        'dccm_size' => 64,
                        'dccm_sadr' => '0xf0040000',
                        'dccm_ecc_width' => 7,
                        'dccm_data_cell' => 'ram_2048x39',
                        'dccm_bits' => 16,
                        'dccm_eadr' => '0xf004ffff',
                        'dccm_reserved' => '0x2004',
                        'lsu_sb_bits' => 16,
                        'dccm_index_bits' => 11,
                        'dccm_offset' => '0x40000',
                        'dccm_enable' => 1
                      },
            'bus' => {
                       'dma_bus_id' => '1',
                       'ifu_bus_tag' => '4',
                       'lsu_bus_id' => '1',
                       'ifu_bus_prty' => '2',
                       'bus_prty_default' => '3',
                       'dma_bus_prty' => '2',
                       'lsu_bus_tag' => '4',
                       'sb_bus_prty' => '2',
                       'dma_bus_tag' => '1',
                       'sb_bus_tag' => '1',
                       'ifu_bus_id' => '1',
                       'sb_bus_id' => '1',
                       'lsu_bus_prty' => '2'
                     },
            'btb' => {
                       'btb_num_bypass' => '8',
                       'btb_array_depth' => 128,
                       'btb_index1_lo' => '3',
                       'btb_num_bypass_width' => 4,
                       'btb_index1_hi' => 9,
                       'btb_addr_hi' => 9,
                       'btb_index2_lo' => 10,
                       'btb_size' => 512,
                       'btb_index2_hi' => 16,
                       'btb_fold2_index_hash' => 0,
                       'btb_use_sram' => '0',
                       'btb_btag_fold' => 0,
                       'btb_bypass_enable' => '1',
                       'btb_index3_hi' => 23,
                       'btb_index3_lo' => 17,
                       'btb_addr_lo' => '3',
                       'btb_btag_size' => 5,
                       'btb_toffset_size' => '12'
                     },
            'xlen' => 32,
            'nmi_vec' => '0x11110000',
            'target' => 'default',
            'regwidth' => '32',
            'numiregs' => '32',
            'perf_events' => [
                               1,
                               2,
                               3,
                               4,
                               5,
                               6,
                               7,
                               8,
                               9,
                               10,
                               11,
                               12,
                               13,
                               14,
                               15,
                               16,
                               17,
                               18,
                               19,
                               20,
                               21,
                               22,
                               23,
                               24,
                               25,
                               26,
                               27,
                               28,
                               29,
                               30,
                               31,
                               32,
                               34,
                               35,
                               36,
                               37,
                               38,
                               39,
                               40,
                               41,
                               42,
                               43,
                               44,
                               45,
                               46,
                               47,
                               48,
                               49,
                               50,
                               51,
                               52,
                               53,
                               54,
                               55,
                               56,
                               512,
                               513,
                               514,
                               515,
                               516
                             ],
            'retstack' => {
                            'ret_stack_size' => '4'
                          },
            'even_odd_trigger_chains' => 'true',
            'tec_rv_icg' => 'clockhdr',
            'max_mmode_perf_event' => '516',
            'testbench' => {
                             'assert_on' => '',
                             'TOP' => 'tb_top',
                             'clock_period' => '100',
                             'build_axi_native' => 1,
                             'ext_addrwidth' => '32',
                             'sterr_rollback' => '0',
                             'ext_datawidth' => '64',
                             'build_axi4' => 1,
                             'SDVT_AHB' => '1',
                             'CPU_TOP' => '`RV_TOP.veer',
                             'RV_TOP' => '`TOP.rvtop',
                             'datawidth' => '64',
                             'lderr_rollback' => '1'
                           },
            'harts' => 1,
            'csr' => {
                       'mhpmevent3' => {
                                         'exists' => 'true',
                                         'reset' => '0x0',
                                         'mask' => '0xffffffff'
                                       },
                       'dcsr' => {
                                   'debug' => 'true',
                                   'poke_mask' => '0x00008dcc',
                                   'exists' => 'true',
                                   'reset' => '0x40000003',
                                   'mask' => '0x00008c04'
                                 },
                       'pmpaddr6' => {
                                       'exists' => 'false'
                                     },
                       'dmst' => {
                                   'comment' => 'Memory synch trigger: Flush caches in debug mode.',
                                   'reset' => '0x0',
                                   'mask' => '0x0',
                                   'debug' => 'true',
                                   'exists' => 'true',
                                   'number' => '0x7c4'
                                 },
                       'pmpaddr1' => {
                                       'exists' => 'false'
                                     },
                       'mimpid' => {
                                     'exists' => 'true',
                                     'reset' => '0x3',
                                     'mask' => '0x0'
                                   },
                       'pmpaddr11' => {
                                        'exists' => 'false'
                                      },
                       'mcounteren' => {
                                         'exists' => 'false'
                                       },
                       'meicidpl' => {
                                       'number' => '0xbcb',
                                       'reset' => '0x0',
                                       'exists' => 'true',
                                       'comment' => 'External interrupt claim id priority level.',
                                       'mask' => '0xf'
                                     },
                       'mhartid' => {
                                      'mask' => '0x0',
                                      'reset' => '0x0',
                                      'exists' => 'true',
                                      'poke_mask' => '0xfffffff0'
                                    },
                       'dicad0' => {
                                     'mask' => '0xffffffff',
                                     'comment' => 'Cache diagnostics.',
                                     'reset' => '0x0',
                                     'debug' => 'true',
                                     'number' => '0x7c9',
                                     'exists' => 'true'
                                   },
                       'pmpaddr15' => {
                                        'exists' => 'false'
                                      },
                       'mitcnt1' => {
                                      'exists' => 'true',
                                      'number' => '0x7d5',
                                      'reset' => '0x0',
                                      'mask' => '0xffffffff'
                                    },
                       'mitcnt0' => {
                                      'mask' => '0xffffffff',
                                      'number' => '0x7d2',
                                      'reset' => '0x0',
                                      'exists' => 'true'
                                    },
                       'mhpmevent4' => {
                                         'reset' => '0x0',
                                         'exists' => 'true',
                                         'mask' => '0xffffffff'
                                       },
                       'mdccmect' => {
                                       'mask' => '0xffffffff',
                                       'number' => '0x7f2',
                                       'reset' => '0x0',
                                       'exists' => 'true'
                                     },
                       'marchid' => {
                                      'mask' => '0x0',
                                      'exists' => 'true',
                                      'reset' => '0x00000011'
                                    },
                       'meipt' => {
                                    'mask' => '0xf',
                                    'comment' => 'External interrupt priority threshold.',
                                    'exists' => 'true',
                                    'reset' => '0x0',
                                    'number' => '0xbc9'
                                  },
                       'mnmipdel' => {
                                       'exists' => 'true',
                                       'number' => '0x7fe',
                                       'shared' => 'true',
                                       'comment' => 'NMI pin delegation',
                                       'reset' => '0x1',
                                       'mask' => '0x1'
                                     },
                       'cycle' => {
                                    'exists' => 'false'
                                  },
                       'dicad1' => {
                                     'debug' => 'true',
                                     'number' => '0x7ca',
                                     'exists' => 'true',
                                     'mask' => '0x3',
                                     'comment' => 'Cache diagnostics.',
                                     'reset' => '0x0'
                                   },
                       'pmpaddr14' => {
                                        'exists' => 'false'
                                      },
                       'dicawics' => {
                                       'number' => '0x7c8',
                                       'exists' => 'true',
                                       'debug' => 'true',
                                       'mask' => '0x0130fffc',
                                       'reset' => '0x0',
                                       'comment' => 'Cache diagnostics.'
                                     },
                       'pmpaddr10' => {
                                        'exists' => 'false'
                                      },
                       'mhpmcounter4h' => {
                                            'exists' => 'true',
                                            'reset' => '0x0',
                                            'mask' => '0xffffffff'
                                          },
                       'mpmc' => {
                                   'mask' => '0x2',
                                   'reset' => '0x2',
                                   'number' => '0x7c6',
                                   'exists' => 'true'
                                 },
                       'time' => {
                                   'exists' => 'false'
                                 },
                       'tselect' => {
                                      'mask' => '0x3',
                                      'exists' => 'true',
                                      'reset' => '0x0'
                                    },
                       'pmpaddr3' => {
                                       'exists' => 'false'
                                     },
                       'pmpaddr12' => {
                                        'exists' => 'false'
                                      },
                       'mhpmcounter5h' => {
                                            'exists' => 'true',
                                            'reset' => '0x0',
                                            'mask' => '0xffffffff'
                                          },
                       'mhartnum' => {
                                       'mask' => '0x0',
                                       'reset' => '0x1',
                                       'comment' => 'Hart count',
                                       'shared' => 'true',
                                       'exists' => 'true',
                                       'number' => '0xfc4'
                                     },
                       'pmpaddr9' => {
                                       'exists' => 'false'
                                     },
                       'dicago' => {
                                     'reset' => '0x0',
                                     'comment' => 'Cache diagnostics.',
                                     'mask' => '0x0',
                                     'exists' => 'true',
                                     'number' => '0x7cb',
                                     'debug' => 'true'
                                   },
                       'mhpmcounter3h' => {
                                            'reset' => '0x0',
                                            'exists' => 'true',
                                            'mask' => '0xffffffff'
                                          },
                       'mhpmcounter6' => {
                                           'mask' => '0xffffffff',
                                           'reset' => '0x0',
                                           'exists' => 'true'
                                         },
                       'pmpaddr8' => {
                                       'exists' => 'false'
                                     },
                       'mhpmevent6' => {
                                         'reset' => '0x0',
                                         'exists' => 'true',
                                         'mask' => '0xffffffff'
                                       },
                       'micect' => {
                                     'mask' => '0xffffffff',
                                     'exists' => 'true',
                                     'reset' => '0x0',
                                     'number' => '0x7f0'
                                   },
                       'mfdhs' => {
                                    'mask' => '0x00000003',
                                    'number' => '0x7cf',
                                    'reset' => '0x0',
                                    'exists' => 'true',
                                    'comment' => 'Force Debug Halt Status'
                                  },
                       'instret' => {
                                      'exists' => 'false'
                                    },
                       'mstatus' => {
                                      'reset' => '0x1800',
                                      'exists' => 'true',
                                      'mask' => '0x88'
                                    },
                       'mhpmcounter3' => {
                                           'mask' => '0xffffffff',
                                           'exists' => 'true',
                                           'reset' => '0x0'
                                         },
                       'mhpmcounter6h' => {
                                            'mask' => '0xffffffff',
                                            'reset' => '0x0',
                                            'exists' => 'true'
                                          },
                       'mcountinhibit' => {
                                            'exists' => 'true',
                                            'commnet' => 'Performance counter inhibit. One bit per counter.',
                                            'reset' => '0x0',
                                            'poke_mask' => '0x7d',
                                            'mask' => '0x7d'
                                          },
                       'pmpaddr7' => {
                                       'exists' => 'false'
                                     },
                       'mitbnd1' => {
                                      'mask' => '0xffffffff',
                                      'exists' => 'true',
                                      'reset' => '0xffffffff',
                                      'number' => '0x7d6'
                                    },
                       'pmpaddr5' => {
                                       'exists' => 'false'
                                     },
                       'mitbnd0' => {
                                      'exists' => 'true',
                                      'number' => '0x7d3',
                                      'reset' => '0xffffffff',
                                      'mask' => '0xffffffff'
                                    },
                       'pmpaddr2' => {
                                       'exists' => 'false'
                                     },
                       'mhartstart' => {
                                         'comment' => 'Hart start mask',
                                         'reset' => '0x1',
                                         'mask' => '0x0',
                                         'exists' => 'true',
                                         'number' => '0x7fc',
                                         'shared' => 'true'
                                       },
                       'mhpmcounter5' => {
                                           'mask' => '0xffffffff',
                                           'reset' => '0x0',
                                           'exists' => 'true'
                                         },
                       'mip' => {
                                  'exists' => 'true',
                                  'reset' => '0x0',
                                  'poke_mask' => '0x70000888',
                                  'mask' => '0x0'
                                },
                       'mhpmcounter4' => {
                                           'mask' => '0xffffffff',
                                           'reset' => '0x0',
                                           'exists' => 'true'
                                         },
                       'meicurpl' => {
                                       'comment' => 'External interrupt current priority level.',
                                       'exists' => 'true',
                                       'reset' => '0x0',
                                       'number' => '0xbcc',
                                       'mask' => '0xf'
                                     },
                       'mvendorid' => {
                                        'mask' => '0x0',
                                        'reset' => '0x45',
                                        'exists' => 'true'
                                      },
                       'miccmect' => {
                                       'exists' => 'true',
                                       'number' => '0x7f1',
                                       'reset' => '0x0',
                                       'mask' => '0xffffffff'
                                     },
                       'misa' => {
                                   'mask' => '0x0',
                                   'reset' => '0x40001105',
                                   'exists' => 'true'
                                 },
                       'mrac' => {
                                   'shared' => 'true',
                                   'exists' => 'true',
                                   'number' => '0x7c0',
                                   'mask' => '0xffffffff',
                                   'comment' => 'Memory region io and cache control.',
                                   'reset' => '0x0'
                                 },
                       'mscause' => {
                                      'mask' => '0x0000000f',
                                      'number' => '0x7ff',
                                      'reset' => '0x0',
                                      'exists' => 'true'
                                    },
                       'mie' => {
                                  'reset' => '0x0',
                                  'exists' => 'true',
                                  'mask' => '0x70000888'
                                },
                       'mfdc' => {
                                   'number' => '0x7f9',
                                   'reset' => '0x00070040',
                                   'exists' => 'true',
                                   'shared' => 'true',
                                   'mask' => '0x00071f4d'
                                 },
                       'pmpcfg3' => {
                                      'exists' => 'false'
                                    },
                       'pmpcfg2' => {
                                      'exists' => 'false'
                                    },
                       'mcgc' => {
                                   'reset' => '0x200',
                                   'mask' => '0x000003ff',
                                   'exists' => 'true',
                                   'number' => '0x7f8',
                                   'poke_mask' => '0x000003ff',
                                   'shared' => 'true'
                                 },
                       'mfdht' => {
                                    'shared' => 'true',
                                    'number' => '0x7ce',
                                    'exists' => 'true',
                                    'mask' => '0x0000003f',
                                    'reset' => '0x0',
                                    'comment' => 'Force Debug Halt Threshold'
                                  },
                       'pmpaddr13' => {
                                        'exists' => 'false'
                                      },
                       'pmpcfg0' => {
                                      'exists' => 'false'
                                    },
                       'pmpcfg1' => {
                                      'exists' => 'false'
                                    },
                       'mitctl0' => {
                                      'reset' => '0x1',
                                      'number' => '0x7d4',
                                      'exists' => 'true',
                                      'mask' => '0x00000007'
                                    },
                       'pmpaddr0' => {
                                       'exists' => 'false'
                                     },
                       'mitctl1' => {
                                      'mask' => '0x0000000f',
                                      'number' => '0x7d7',
                                      'reset' => '0x1',
                                      'exists' => 'true'
                                    },
                       'pmpaddr4' => {
                                       'exists' => 'false'
                                     },
                       'mcpc' => {
                                   'mask' => '0x0',
                                   'comment' => 'Core pause',
                                   'exists' => 'true',
                                   'number' => '0x7c2',
                                   'reset' => '0x0'
                                 },
                       'mhpmevent5' => {
                                         'mask' => '0xffffffff',
                                         'exists' => 'true',
                                         'reset' => '0x0'
                                       }
                     },
            'core' => {
                        'num_threads' => 1,
                        'no_iccm_no_icache' => 'derived',
                        'fast_interrupt_redirect' => '1',
                        'bitmanip_zbp' => 0,
                        'bitmanip_zbe' => 0,
                        'dma_buf_depth' => '5',
                        'iccm_only' => 'derived',
                        'lsu_num_nbload_width' => '3',
                        'lsu_num_nbload' => '8',
                        'bitmanip_zbf' => 0,
                        'lsu_stbuf_depth' => '10',
                        'iccm_icache' => 1,
                        'timer_legal_en' => '1',
                        'bitmanip_zbc' => 1,
                        'bitmanip_zbr' => 0,
                        'atomic_enable' => '1',
                        'bitmanip_zbs' => 1,
                        'bitmanip_zba' => 1,
                        'fpga_optimize' => 1,
                        'icache_only' => 'derived',
                        'bitmanip_zbb' => 1,
                        'div_bit' => '4',
                        'div_new' => 1
                      },
            'protection' => {
                              'data_access_mask1' => '0x3fffffff',
                              'data_access_mask3' => '0x0fffffff',
                              'data_access_addr6' => '0x00000000',
                              'data_access_enable6' => '0x0',
                              'inst_access_addr7' => '0x00000000',
                              'data_access_mask5' => '0xffffffff',
                              'data_access_addr2' => '0xa0000000',
                              'inst_access_enable2' => '1',
                              'inst_access_enable1' => '1',
                              'data_access_mask0' => '0x7fffffff',
                              'inst_access_addr4' => '0x00000000',
                              'inst_access_addr0' => '0x0',
                              'data_access_mask4' => '0xffffffff',
                              'inst_access_enable0' => '1',
                              'data_access_enable7' => '0x0',
                              'inst_access_enable3' => '1',
                              'inst_access_mask2' => '0x1fffffff',
                              'inst_access_addr5' => '0x00000000',
                              'data_access_mask7' => '0xffffffff',
                              'inst_access_enable4' => '0x0',
                              'inst_access_addr3' => '0x80000000',
                              'inst_access_enable5' => '0x0',
                              'inst_access_addr1' => '0xc0000000',
                              'inst_access_mask6' => '0xffffffff',
                              'data_access_enable0' => '1',
                              'inst_access_mask4' => '0xffffffff',
                              'data_access_addr0' => '0x0',
                              'inst_access_enable7' => '0x0',
                              'data_access_enable3' => '1',
                              'data_access_mask2' => '0x1fffffff',
                              'inst_access_mask7' => '0xffffffff',
                              'data_access_addr5' => '0x00000000',
                              'data_access_enable4' => '0x0',
                              'data_access_addr1' => '0xc0000000',
                              'data_access_addr3' => '0x80000000',
                              'data_access_enable5' => '0x0',
                              'data_access_mask6' => '0xffffffff',
                              'inst_access_mask3' => '0x0fffffff',
                              'inst_access_mask1' => '0x3fffffff',
                              'inst_access_enable6' => '0x0',
                              'inst_access_addr6' => '0x00000000',
                              'inst_access_mask5' => '0xffffffff',
                              'data_access_addr7' => '0x00000000',
                              'data_access_enable2' => '1',
                              'inst_access_addr2' => '0xa0000000',
                              'inst_access_mask0' => '0x7fffffff',
                              'data_access_addr4' => '0x00000000',
                              'data_access_enable1' => '1'
                            },
            'target_default' => '1',
            'num_mmode_perf_regs' => '4',
            'physical' => '1'
          );
1;
