修改完成，所有状态衔接都正确。完整时序回顾：
                                                                                                                                  
  完整的配置序列时序                                                                                                              
                                                                                                                                  
  idx=0  ── ENTER REGISTER MODE (完整 read frame)                                                                                 
     IDLE → SETUP(6c, db_oe=1, db_out=8100h, R/W=1)                                                                               
          → WRLOW(10c, WR↓)        // WR↑ 锁存读命令到芯片                                                                        
          → HOLD(6c, WR↑)                                                                                                         
          → RD_PRE(6c, db_oe=0)    // 释放总线给芯片                                                                              
          → RDLOW(6c, RD↓)         // 第二帧：芯片真正把寄存器内容送出                                                            
          → RDHIGH(6c, RD↑)        // 读帧结束，正式进入 register mode                                                            
          → NEXT                                                                                                                  
                                                                                                                                  
  idx=1..5 ── REGISTER WRITES (单帧)                                                                                              
     SETUP(db_oe=1, db_out={1'b0, addr, data})
          → WRLOW(WR↓)                                                                                                            
          → HOLD(WR↑)              // WR↑ 锁存写数据
          → NEXT                                                                                                                  
                  
  idx=6  ── EXIT REGISTER MODE (单帧 dummy write)                                                                                 
     SETUP(db_out=0000h)
          → WRLOW                                                                                                                 
          → HOLD                    // WR↑ 时 DBx 全 0 → 退回 ADC mode
          → NEXT → DONE                                                                                                           
                  
  DONE: ad_cs=1, db_oe=0, cfgw_done=1   // 交给采样 FSM                                                                           
                  
  几个关键安全点                                                                                                                  
                  
  1. 总线方向切换：CFGW_RD_PRE 提前 6 个时钟周期（30ns）将 db_oe 拉低释放总线，给 IOBUF                                           
    翻转方向留出充足的死区，避免与芯片驱动冲突。
  2. db_oe 重新使能：进入 CFGW_NEXT 后转回 CFGW_SETUP，第一行 db_oe <= 1'b1 立刻重新接管总线，没有遗留的高阻态写。                
  3. ad_rd 默认值：复位段已经把 ad_rd <= 1'b1，进入 CFGW_RDLOW 之前一直保持高，没有意外早拉低。                                   
  4. cfgw_state 位宽：拓宽到 4 bit，9 个状态全部容纳（0~8）。原先的 [2:0] 已经被替换，没有遗留旧位宽访问。                        
  5. 采样 FSM (conv_state) 的等待：仍然依赖 cfgw_done 标志，只会在所有 7 帧（含进入/退出）发完之后才开始拉                        
    CONVST，与之前行为一致。                                                                                                        
                                                                                                                                  

  这下就严格符合数据手册图 101 描述的"REGISTER MODE = 一个完整的读 → 多个写 → 一个 DBx=0 的写退出"序列了。建议综合后用 ILA 抓 CS /
   RD / WR / db_out 在配置阶段的波形，确认看到：1 个 WR 脉冲(R/W=1) → 1 个 RD 脉冲 → 5 个 WR 脉冲(写) → 1 个 WR 脉冲(全 0)，共 7
  个 WR + 1 个 RD。                                            