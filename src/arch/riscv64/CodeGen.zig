const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const Air = @import("../../Air.zig");
const Mir = @import("Mir.zig");
const Emit = @import("Emit.zig");
const Liveness = @import("../../Liveness.zig");
const Type = @import("../../Type.zig");
const Value = @import("../../Value.zig");
const link = @import("../../link.zig");
const Zcu = @import("../../Zcu.zig");
const Package = @import("../../Package.zig");
const InternPool = @import("../../InternPool.zig");
const Compilation = @import("../../Compilation.zig");
const ErrorMsg = Zcu.ErrorMsg;
const Target = std.Target;
const Allocator = mem.Allocator;
const trace = @import("../../tracy.zig").trace;
const DW = std.dwarf;
const leb128 = std.leb;
const log = std.log.scoped(.riscv_codegen);
const tracking_log = std.log.scoped(.tracking);
const verbose_tracking_log = std.log.scoped(.verbose_tracking);
const wip_mir_log = std.log.scoped(.wip_mir);
const build_options = @import("build_options");
const codegen = @import("../../codegen.zig");
const Alignment = InternPool.Alignment;

const CodeGenError = codegen.CodeGenError;
const Result = codegen.Result;
const DebugInfoOutput = codegen.DebugInfoOutput;

const bits = @import("bits.zig");
const abi = @import("abi.zig");
const Lower = @import("Lower.zig");

const Register = bits.Register;
const Immediate = bits.Immediate;
const Memory = bits.Memory;
const FrameIndex = bits.FrameIndex;
const RegisterManager = abi.RegisterManager;
const RegisterLock = RegisterManager.RegisterLock;

const InnerError = CodeGenError || error{OutOfRegisters};

gpa: Allocator,
air: Air,
mod: *Package.Module,
liveness: Liveness,
bin_file: *link.File,
target: *const std.Target,
func_index: InternPool.Index,
code: *std.ArrayList(u8),
debug_output: DebugInfoOutput,
err_msg: ?*ErrorMsg,
args: []MCValue,
ret_mcv: InstTracking,
fn_type: Type,
arg_index: usize,
src_loc: Zcu.LazySrcLoc,

/// MIR Instructions
mir_instructions: std.MultiArrayList(Mir.Inst) = .{},
/// MIR extra data
mir_extra: std.ArrayListUnmanaged(u32) = .{},

/// Byte offset within the source file of the ending curly.
end_di_line: u32,
end_di_column: u32,

scope_generation: u32,

/// The value is an offset into the `Function` `code` from the beginning.
/// To perform the reloc, write 32-bit signed little-endian integer
/// which is a relative jump, based on the address following the reloc.
exitlude_jump_relocs: std.ArrayListUnmanaged(usize) = .{},

/// Whenever there is a runtime branch, we push a Branch onto this stack,
/// and pop it off when the runtime branch joins. This provides an "overlay"
/// of the table of mappings from instructions to `MCValue` from within the branch.
/// This way we can modify the `MCValue` for an instruction in different ways
/// within different branches. Special consideration is needed when a branch
/// joins with its parent, to make sure all instructions have the same MCValue
/// across each runtime branch upon joining.
branch_stack: *std.ArrayList(Branch),

// Key is the block instruction
blocks: std.AutoHashMapUnmanaged(Air.Inst.Index, BlockData) = .{},
register_manager: RegisterManager = .{},

const_tracking: ConstTrackingMap = .{},
inst_tracking: InstTrackingMap = .{},

frame_allocs: std.MultiArrayList(FrameAlloc) = .{},
free_frame_indices: std.AutoArrayHashMapUnmanaged(FrameIndex, void) = .{},
frame_locs: std.MultiArrayList(Mir.FrameLoc) = .{},

/// Debug field, used to find bugs in the compiler.
air_bookkeeping: @TypeOf(air_bookkeeping_init) = air_bookkeeping_init,

const air_bookkeeping_init = if (std.debug.runtime_safety) @as(usize, 0) else {};

const SymbolOffset = struct { sym: u32, off: i32 = 0 };
const RegisterOffset = struct { reg: Register, off: i32 = 0 };
pub const FrameAddr = struct { index: FrameIndex, off: i32 = 0 };

const MCValue = union(enum) {
    /// No runtime bits. `void` types, empty structs, u0, enums with 1 tag, etc.
    /// TODO Look into deleting this tag and using `dead` instead, since every use
    /// of MCValue.none should be instead looking at the type and noticing it is 0 bits.
    none,
    /// Control flow will not allow this value to be observed.
    unreach,
    /// No more references to this value remain.
    /// The payload is the value of scope_generation at the point where the death occurred
    dead: u32,
    /// The value is undefined.
    undef,
    /// A pointer-sized integer that fits in a register.
    /// If the type is a pointer, this is the pointer address in virtual address space.
    immediate: u64,
    /// The value doesn't exist in memory yet.
    load_symbol: SymbolOffset,
    /// The address of the memory location not-yet-allocated by the linker.
    lea_symbol: SymbolOffset,
    /// The value is in a target-specific register.
    register: Register,
    /// The value is split across two registers
    register_pair: [2]Register,
    /// The value is in memory at a hard-coded address.
    /// If the type is a pointer, it means the pointer address is at this memory location.
    memory: u64,
    /// The value stored at an offset from a frame index
    /// Payload is a frame address.
    load_frame: FrameAddr,
    /// The address of an offset from a frame index
    /// Payload is a frame address.
    lea_frame: FrameAddr,
    air_ref: Air.Inst.Ref,
    /// The value is in memory at a constant offset from the address in a register.
    indirect: RegisterOffset,
    /// The value is a constant offset from the value in a register.
    register_offset: RegisterOffset,
    /// This indicates that we have already allocated a frame index for this instruction,
    /// but it has not been spilled there yet in the current control flow.
    /// Payload is a frame index.
    reserved_frame: FrameIndex,

    fn isMemory(mcv: MCValue) bool {
        return switch (mcv) {
            .memory, .indirect, .load_frame => true,
            else => false,
        };
    }

    fn isImmediate(mcv: MCValue) bool {
        return switch (mcv) {
            .immediate => true,
            else => false,
        };
    }

    fn isRegister(mcv: MCValue) bool {
        return switch (mcv) {
            .register => true,
            .register_offset => |reg_off| return reg_off.off == 0,
            else => false,
        };
    }

    fn isMutable(mcv: MCValue) bool {
        return switch (mcv) {
            .none => unreachable,
            .unreach => unreachable,
            .dead => unreachable,

            .immediate,
            .memory,
            .lea_frame,
            .undef,
            .lea_symbol,
            .air_ref,
            .reserved_frame,
            => false,

            .register,
            .register_pair,
            .register_offset,
            .load_frame,
            .load_symbol,
            .indirect,
            => true,
        };
    }

    fn address(mcv: MCValue) MCValue {
        return switch (mcv) {
            .none,
            .unreach,
            .dead,
            .immediate,
            .lea_frame,
            .register_offset,
            .register_pair,
            .register,
            .undef,
            .air_ref,
            .lea_symbol,
            .reserved_frame,
            => unreachable, // not in memory

            .load_symbol => |sym_off| .{ .lea_symbol = sym_off },
            .memory => |addr| .{ .immediate = addr },
            .load_frame => |off| .{ .lea_frame = off },
            .indirect => |reg_off| switch (reg_off.off) {
                0 => .{ .register = reg_off.reg },
                else => .{ .register_offset = reg_off },
            },
        };
    }

    fn deref(mcv: MCValue) MCValue {
        return switch (mcv) {
            .none,
            .unreach,
            .dead,
            .memory,
            .indirect,
            .undef,
            .air_ref,
            .load_frame,
            .register_pair,
            .load_symbol,
            .reserved_frame,
            => unreachable, // not a pointer

            .immediate => |addr| .{ .memory = addr },
            .lea_frame => |off| .{ .load_frame = off },
            .register => |reg| .{ .indirect = .{ .reg = reg } },
            .register_offset => |reg_off| .{ .indirect = reg_off },
            .lea_symbol => |sym_off| .{ .load_symbol = sym_off },
        };
    }

    fn offset(mcv: MCValue, off: i32) MCValue {
        return switch (mcv) {
            .none,
            .unreach,
            .dead,
            .undef,
            .air_ref,
            .reserved_frame,
            => unreachable, // not valid
            .register_pair,
            .memory,
            .indirect,
            .load_frame,
            .load_symbol,
            .lea_symbol,
            => switch (off) {
                0 => mcv,
                else => unreachable, // not offsettable
            },
            .immediate => |imm| .{ .immediate = @bitCast(@as(i64, @bitCast(imm)) +% off) },
            .register => |reg| .{ .register_offset = .{ .reg = reg, .off = off } },
            .register_offset => |reg_off| .{ .register_offset = .{ .reg = reg_off.reg, .off = reg_off.off + off } },
            .lea_frame => |frame_addr| .{
                .lea_frame = .{ .index = frame_addr.index, .off = frame_addr.off + off },
            },
        };
    }

    fn getReg(mcv: MCValue) ?Register {
        return switch (mcv) {
            .register => |reg| reg,
            .register_offset, .indirect => |ro| ro.reg,
            else => null,
        };
    }

    fn getRegs(mcv: *const MCValue) []const Register {
        return switch (mcv.*) {
            .register => |*reg| @as(*const [1]Register, reg),
            .register_pair => |*regs| regs,
            .register_offset, .indirect => |*ro| @as(*const [1]Register, &ro.reg),
            else => &.{},
        };
    }
};

const Branch = struct {
    inst_table: std.AutoArrayHashMapUnmanaged(Air.Inst.Index, MCValue) = .{},

    fn deinit(func: *Branch, gpa: Allocator) void {
        func.inst_table.deinit(gpa);
        func.* = undefined;
    }
};

const InstTrackingMap = std.AutoArrayHashMapUnmanaged(Air.Inst.Index, InstTracking);
const ConstTrackingMap = std.AutoArrayHashMapUnmanaged(InternPool.Index, InstTracking);

const InstTracking = struct {
    long: MCValue,
    short: MCValue,

    fn init(result: MCValue) InstTracking {
        return .{ .long = switch (result) {
            .none,
            .unreach,
            .undef,
            .immediate,
            .memory,
            .load_frame,
            .lea_frame,
            .load_symbol,
            .lea_symbol,
            => result,
            .dead,
            .reserved_frame,
            .air_ref,
            => unreachable,
            .register,
            .register_pair,
            .register_offset,
            .indirect,
            => .none,
        }, .short = result };
    }

    fn getReg(inst_tracking: InstTracking) ?Register {
        return inst_tracking.short.getReg();
    }

    fn getRegs(inst_tracking: *const InstTracking) []const Register {
        return inst_tracking.short.getRegs();
    }

    fn spill(inst_tracking: *InstTracking, function: *Func, inst: Air.Inst.Index) !void {
        if (std.meta.eql(inst_tracking.long, inst_tracking.short)) return; // Already spilled
        // Allocate or reuse frame index
        switch (inst_tracking.long) {
            .none => inst_tracking.long = try function.allocRegOrMem(
                function.typeOfIndex(inst),
                inst,
                false,
            ),
            .load_frame => {},
            .reserved_frame => |index| inst_tracking.long = .{ .load_frame = .{ .index = index } },
            else => unreachable,
        }
        tracking_log.debug("spill %{d} from {} to {}", .{ inst, inst_tracking.short, inst_tracking.long });
        try function.genCopy(function.typeOfIndex(inst), inst_tracking.long, inst_tracking.short);
    }

    fn reuseFrame(inst_tracking: *InstTracking) void {
        switch (inst_tracking.long) {
            .reserved_frame => |index| inst_tracking.long = .{ .load_frame = .{ .index = index } },
            else => {},
        }
        inst_tracking.short = switch (inst_tracking.long) {
            .none,
            .unreach,
            .undef,
            .immediate,
            .memory,
            .load_frame,
            .lea_frame,
            .load_symbol,
            .lea_symbol,
            => inst_tracking.long,
            .dead,
            .register,
            .register_pair,
            .register_offset,
            .indirect,
            .reserved_frame,
            .air_ref,
            => unreachable,
        };
    }

    fn trackSpill(inst_tracking: *InstTracking, function: *Func, inst: Air.Inst.Index) !void {
        try function.freeValue(inst_tracking.short);
        inst_tracking.reuseFrame();
        tracking_log.debug("%{d} => {} (spilled)", .{ inst, inst_tracking.* });
    }

    fn verifyMaterialize(inst_tracking: InstTracking, target: InstTracking) void {
        switch (inst_tracking.long) {
            .none,
            .unreach,
            .undef,
            .immediate,
            .memory,
            .lea_frame,
            .load_symbol,
            .lea_symbol,
            => assert(std.meta.eql(inst_tracking.long, target.long)),
            .load_frame,
            .reserved_frame,
            => switch (target.long) {
                .none,
                .load_frame,
                .reserved_frame,
                => {},
                else => unreachable,
            },
            .dead,
            .register,
            .register_pair,
            .register_offset,
            .indirect,
            .air_ref,
            => unreachable,
        }
    }

    fn materialize(
        inst_tracking: *InstTracking,
        function: *Func,
        inst: Air.Inst.Index,
        target: InstTracking,
    ) !void {
        inst_tracking.verifyMaterialize(target);
        try inst_tracking.materializeUnsafe(function, inst, target);
    }

    fn materializeUnsafe(
        inst_tracking: InstTracking,
        function: *Func,
        inst: Air.Inst.Index,
        target: InstTracking,
    ) !void {
        const ty = function.typeOfIndex(inst);
        if ((inst_tracking.long == .none or inst_tracking.long == .reserved_frame) and target.long == .load_frame)
            try function.genCopy(ty, target.long, inst_tracking.short);
        try function.genCopy(ty, target.short, inst_tracking.short);
    }

    fn trackMaterialize(inst_tracking: *InstTracking, inst: Air.Inst.Index, target: InstTracking) void {
        inst_tracking.verifyMaterialize(target);
        // Don't clobber reserved frame indices
        inst_tracking.long = if (target.long == .none) switch (inst_tracking.long) {
            .load_frame => |addr| .{ .reserved_frame = addr.index },
            .reserved_frame => inst_tracking.long,
            else => target.long,
        } else target.long;
        inst_tracking.short = target.short;
        tracking_log.debug("%{d} => {} (materialize)", .{ inst, inst_tracking.* });
    }

    fn resurrect(inst_tracking: *InstTracking, inst: Air.Inst.Index, scope_generation: u32) void {
        switch (inst_tracking.short) {
            .dead => |die_generation| if (die_generation >= scope_generation) {
                inst_tracking.reuseFrame();
                tracking_log.debug("%{d} => {} (resurrect)", .{ inst, inst_tracking.* });
            },
            else => {},
        }
    }

    fn die(inst_tracking: *InstTracking, function: *Func, inst: Air.Inst.Index) !void {
        if (inst_tracking.short == .dead) return;
        try function.freeValue(inst_tracking.short);
        inst_tracking.short = .{ .dead = function.scope_generation };
        tracking_log.debug("%{d} => {} (death)", .{ inst, inst_tracking.* });
    }

    fn reuse(
        inst_tracking: *InstTracking,
        function: *Func,
        new_inst: ?Air.Inst.Index,
        old_inst: Air.Inst.Index,
    ) void {
        inst_tracking.short = .{ .dead = function.scope_generation };
        if (new_inst) |inst|
            tracking_log.debug("%{d} => {} (reuse %{d})", .{ inst, inst_tracking.*, old_inst })
        else
            tracking_log.debug("tmp => {} (reuse %{d})", .{ inst_tracking.*, old_inst });
    }

    fn liveOut(inst_tracking: *InstTracking, function: *Func, inst: Air.Inst.Index) void {
        for (inst_tracking.getRegs()) |reg| {
            if (function.register_manager.isRegFree(reg)) {
                tracking_log.debug("%{d} => {} (live-out)", .{ inst, inst_tracking.* });
                continue;
            }

            const index = RegisterManager.indexOfRegIntoTracked(reg).?;
            const tracked_inst = function.register_manager.registers[index];
            const tracking = function.getResolvedInstValue(tracked_inst);

            // Disable death.
            var found_reg = false;
            var remaining_reg: Register = .zero;
            for (tracking.getRegs()) |tracked_reg| if (tracked_reg.id() == reg.id()) {
                assert(!found_reg);
                found_reg = true;
            } else {
                assert(remaining_reg == .zero);
                remaining_reg = tracked_reg;
            };
            assert(found_reg);
            tracking.short = switch (remaining_reg) {
                .zero => .{ .dead = function.scope_generation },
                else => .{ .register = remaining_reg },
            };

            // Perform side-effects of freeValue manually.
            function.register_manager.freeReg(reg);

            tracking_log.debug("%{d} => {} (live-out %{d})", .{ inst, inst_tracking.*, tracked_inst });
        }
    }

    pub fn format(
        inst_tracking: InstTracking,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        if (!std.meta.eql(inst_tracking.long, inst_tracking.short)) try writer.print("|{}| ", .{inst_tracking.long});
        try writer.print("{}", .{inst_tracking.short});
    }
};

const FrameAlloc = struct {
    abi_size: u31,
    spill_pad: u3,
    abi_align: Alignment,
    ref_count: u16,

    fn init(alloc_abi: struct { size: u64, pad: u3 = 0, alignment: Alignment }) FrameAlloc {
        return .{
            .abi_size = @intCast(alloc_abi.size),
            .spill_pad = alloc_abi.pad,
            .abi_align = alloc_abi.alignment,
            .ref_count = 0,
        };
    }
    fn initType(ty: Type, zcu: *Zcu) FrameAlloc {
        return init(.{
            .size = ty.abiSize(zcu),
            .alignment = ty.abiAlignment(zcu),
        });
    }
    fn initSpill(ty: Type, zcu: *Zcu) FrameAlloc {
        const abi_size = ty.abiSize(zcu);
        const spill_size = if (abi_size < 8)
            math.ceilPowerOfTwoAssert(u64, abi_size)
        else
            std.mem.alignForward(u64, abi_size, 8);
        return init(.{
            .size = spill_size,
            .pad = @intCast(spill_size - abi_size),
            .alignment = ty.abiAlignment(zcu).maxStrict(
                Alignment.fromNonzeroByteUnits(@min(spill_size, 8)),
            ),
        });
    }
};

const BlockData = struct {
    relocs: std.ArrayListUnmanaged(Mir.Inst.Index) = .{},
    state: State,

    fn deinit(bd: *BlockData, gpa: Allocator) void {
        bd.relocs.deinit(gpa);
        bd.* = undefined;
    }
};

const State = struct {
    registers: RegisterManager.TrackedRegisters,
    reg_tracking: [RegisterManager.RegisterBitSet.bit_length]InstTracking,
    free_registers: RegisterManager.RegisterBitSet,
    inst_tracking_len: u32,
    scope_generation: u32,
};

fn initRetroactiveState(func: *Func) State {
    var state: State = undefined;
    state.inst_tracking_len = @intCast(func.inst_tracking.count());
    state.scope_generation = func.scope_generation;
    return state;
}

fn saveRetroactiveState(func: *Func, state: *State) !void {
    const free_registers = func.register_manager.free_registers;
    var it = free_registers.iterator(.{ .kind = .unset });
    while (it.next()) |index| {
        const tracked_inst = func.register_manager.registers[index];
        state.registers[index] = tracked_inst;
        state.reg_tracking[index] = func.inst_tracking.get(tracked_inst).?;
    }
    state.free_registers = free_registers;
}

fn saveState(func: *Func) !State {
    var state = func.initRetroactiveState();
    try func.saveRetroactiveState(&state);
    return state;
}

fn restoreState(func: *Func, state: State, deaths: []const Air.Inst.Index, comptime opts: struct {
    emit_instructions: bool,
    update_tracking: bool,
    resurrect: bool,
    close_scope: bool,
}) !void {
    if (opts.close_scope) {
        for (
            func.inst_tracking.keys()[state.inst_tracking_len..],
            func.inst_tracking.values()[state.inst_tracking_len..],
        ) |inst, *tracking| try tracking.die(func, inst);
        func.inst_tracking.shrinkRetainingCapacity(state.inst_tracking_len);
    }

    if (opts.resurrect) for (
        func.inst_tracking.keys()[0..state.inst_tracking_len],
        func.inst_tracking.values()[0..state.inst_tracking_len],
    ) |inst, *tracking| tracking.resurrect(inst, state.scope_generation);
    for (deaths) |death| try func.processDeath(death);

    const ExpectedContents = [@typeInfo(RegisterManager.TrackedRegisters).Array.len]RegisterLock;
    var stack align(@max(@alignOf(ExpectedContents), @alignOf(std.heap.StackFallbackAllocator(0)))) =
        if (opts.update_tracking)
    {} else std.heap.stackFallback(@sizeOf(ExpectedContents), func.gpa);

    var reg_locks = if (opts.update_tracking) {} else try std.ArrayList(RegisterLock).initCapacity(
        stack.get(),
        @typeInfo(ExpectedContents).Array.len,
    );
    defer if (!opts.update_tracking) {
        for (reg_locks.items) |lock| func.register_manager.unlockReg(lock);
        reg_locks.deinit();
    };

    for (0..state.registers.len) |index| {
        const current_maybe_inst = if (func.register_manager.free_registers.isSet(index))
            null
        else
            func.register_manager.registers[index];
        const target_maybe_inst = if (state.free_registers.isSet(index))
            null
        else
            state.registers[index];
        if (std.debug.runtime_safety) if (target_maybe_inst) |target_inst|
            assert(func.inst_tracking.getIndex(target_inst).? < state.inst_tracking_len);
        if (opts.emit_instructions) {
            if (current_maybe_inst) |current_inst| {
                try func.inst_tracking.getPtr(current_inst).?.spill(func, current_inst);
            }
            if (target_maybe_inst) |target_inst| {
                const target_tracking = func.inst_tracking.getPtr(target_inst).?;
                try target_tracking.materialize(func, target_inst, state.reg_tracking[index]);
            }
        }
        if (opts.update_tracking) {
            if (current_maybe_inst) |current_inst| {
                try func.inst_tracking.getPtr(current_inst).?.trackSpill(func, current_inst);
            }
            blk: {
                const inst = target_maybe_inst orelse break :blk;
                const reg = RegisterManager.regAtTrackedIndex(@intCast(index));
                func.register_manager.freeReg(reg);
                func.register_manager.getRegAssumeFree(reg, inst);
            }
            if (target_maybe_inst) |target_inst| {
                func.inst_tracking.getPtr(target_inst).?.trackMaterialize(
                    target_inst,
                    state.reg_tracking[index],
                );
            }
        } else if (target_maybe_inst) |_|
            try reg_locks.append(func.register_manager.lockRegIndexAssumeUnused(@intCast(index)));
    }

    if (opts.update_tracking and std.debug.runtime_safety) {
        assert(func.register_manager.free_registers.eql(state.free_registers));
        var used_reg_it = state.free_registers.iterator(.{ .kind = .unset });
        while (used_reg_it.next()) |index|
            assert(func.register_manager.registers[index] == state.registers[index]);
    }
}

const Func = @This();

const CallView = enum(u1) {
    callee,
    caller,
};

pub fn generate(
    bin_file: *link.File,
    src_loc: Zcu.LazySrcLoc,
    func_index: InternPool.Index,
    air: Air,
    liveness: Liveness,
    code: *std.ArrayList(u8),
    debug_output: DebugInfoOutput,
) CodeGenError!Result {
    const comp = bin_file.comp;
    const gpa = comp.gpa;
    const zcu = comp.module.?;
    const ip = &zcu.intern_pool;
    const func = zcu.funcInfo(func_index);
    const fn_owner_decl = zcu.declPtr(func.owner_decl);
    assert(fn_owner_decl.has_tv);
    const fn_type = fn_owner_decl.typeOf(zcu);
    const namespace = zcu.namespacePtr(fn_owner_decl.src_namespace);
    const target = &namespace.fileScope(zcu).mod.resolved_target.result;
    const mod = namespace.fileScope(zcu).mod;

    var branch_stack = std.ArrayList(Branch).init(gpa);
    defer {
        assert(branch_stack.items.len == 1);
        branch_stack.items[0].deinit(gpa);
        branch_stack.deinit();
    }
    try branch_stack.append(.{});

    var function = Func{
        .gpa = gpa,
        .air = air,
        .mod = mod,
        .liveness = liveness,
        .target = target,
        .bin_file = bin_file,
        .func_index = func_index,
        .code = code,
        .debug_output = debug_output,
        .err_msg = null,
        .args = undefined, // populated after `resolveCallingConventionValues`
        .ret_mcv = undefined, // populated after `resolveCallingConventionValues`
        .fn_type = fn_type,
        .arg_index = 0,
        .branch_stack = &branch_stack,
        .src_loc = src_loc,
        .end_di_line = func.rbrace_line,
        .end_di_column = func.rbrace_column,
        .scope_generation = 0,
    };
    defer {
        function.frame_allocs.deinit(gpa);
        function.free_frame_indices.deinit(gpa);
        function.frame_locs.deinit(gpa);
        var block_it = function.blocks.valueIterator();
        while (block_it.next()) |block| block.deinit(gpa);
        function.blocks.deinit(gpa);
        function.inst_tracking.deinit(gpa);
        function.const_tracking.deinit(gpa);
        function.exitlude_jump_relocs.deinit(gpa);
        function.mir_instructions.deinit(gpa);
        function.mir_extra.deinit(gpa);
    }

    wip_mir_log.debug("{}:", .{function.fmtDecl(func.owner_decl)});

    try function.frame_allocs.resize(gpa, FrameIndex.named_count);
    function.frame_allocs.set(
        @intFromEnum(FrameIndex.stack_frame),
        FrameAlloc.init(.{
            .size = 0,
            .alignment = func.analysis(ip).stack_alignment.max(.@"1"),
        }),
    );
    function.frame_allocs.set(
        @intFromEnum(FrameIndex.call_frame),
        FrameAlloc.init(.{ .size = 0, .alignment = .@"1" }),
    );

    const fn_info = zcu.typeToFunc(fn_type).?;
    var call_info = function.resolveCallingConventionValues(fn_info, &.{}) catch |err| switch (err) {
        error.CodegenFail => return Result{ .fail = function.err_msg.? },
        error.OutOfRegisters => return Result{
            .fail = try ErrorMsg.create(gpa, src_loc, "CodeGen ran out of registers. This is a bug in the Zig compiler.", .{}),
        },
        else => |e| return e,
    };

    defer call_info.deinit(&function);

    function.args = call_info.args;
    function.ret_mcv = call_info.return_value;
    function.frame_allocs.set(@intFromEnum(FrameIndex.ret_addr), FrameAlloc.init(.{
        .size = Type.usize.abiSize(zcu),
        .alignment = Type.usize.abiAlignment(zcu).min(call_info.stack_align),
    }));
    function.frame_allocs.set(@intFromEnum(FrameIndex.base_ptr), FrameAlloc.init(.{
        .size = Type.usize.abiSize(zcu),
        .alignment = Alignment.min(
            call_info.stack_align,
            Alignment.fromNonzeroByteUnits(function.target.stackAlignment()),
        ),
    }));
    function.frame_allocs.set(@intFromEnum(FrameIndex.args_frame), FrameAlloc.init(.{
        .size = call_info.stack_byte_count,
        .alignment = call_info.stack_align,
    }));
    function.frame_allocs.set(@intFromEnum(FrameIndex.spill_frame), FrameAlloc.init(.{
        .size = 0,
        .alignment = Type.usize.abiAlignment(zcu),
    }));

    function.gen() catch |err| switch (err) {
        error.CodegenFail => return Result{ .fail = function.err_msg.? },
        error.OutOfRegisters => return Result{
            .fail = try ErrorMsg.create(gpa, src_loc, "CodeGen ran out of registers. This is a bug in the Zig compiler.", .{}),
        },
        else => |e| return e,
    };

    var mir = Mir{
        .instructions = function.mir_instructions.toOwnedSlice(),
        .extra = try function.mir_extra.toOwnedSlice(gpa),
        .frame_locs = function.frame_locs.toOwnedSlice(),
    };
    defer mir.deinit(gpa);

    var emit = Emit{
        .lower = .{
            .bin_file = bin_file,
            .allocator = gpa,
            .mir = mir,
            .cc = fn_info.cc,
            .src_loc = src_loc,
            .output_mode = comp.config.output_mode,
            .link_mode = comp.config.link_mode,
            .pic = mod.pic,
        },
        .debug_output = debug_output,
        .code = code,
        .prev_di_pc = 0,
        .prev_di_line = func.lbrace_line,
        .prev_di_column = func.lbrace_column,
    };
    defer emit.deinit();

    emit.emitMir() catch |err| switch (err) {
        error.LowerFail, error.EmitFail => return Result{ .fail = emit.lower.err_msg.? },
        error.InvalidInstruction => |e| {
            const msg = switch (e) {
                error.InvalidInstruction => "CodeGen failed to find a viable instruction.",
            };
            return Result{
                .fail = try ErrorMsg.create(
                    gpa,
                    src_loc,
                    "{s} This is a bug in the Zig compiler.",
                    .{msg},
                ),
            };
        },
        else => |e| return e,
    };

    if (function.err_msg) |em| {
        return Result{ .fail = em };
    } else {
        return Result.ok;
    }
}

const FormatWipMirData = struct {
    func: *Func,
    inst: Mir.Inst.Index,
};
fn formatWipMir(
    data: FormatWipMirData,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) @TypeOf(writer).Error!void {
    const comp = data.func.bin_file.comp;
    const mod = comp.root_mod;
    var lower = Lower{
        .bin_file = data.func.bin_file,
        .allocator = data.func.gpa,
        .mir = .{
            .instructions = data.func.mir_instructions.slice(),
            .extra = data.func.mir_extra.items,
            .frame_locs = data.func.frame_locs.slice(),
        },
        .cc = .Unspecified,
        .src_loc = data.func.src_loc,
        .output_mode = comp.config.output_mode,
        .link_mode = comp.config.link_mode,
        .pic = mod.pic,
    };
    var first = true;
    for ((lower.lowerMir(data.inst) catch |err| switch (err) {
        error.LowerFail => {
            defer {
                lower.err_msg.?.deinit(data.func.gpa);
                lower.err_msg = null;
            }
            try writer.writeAll(lower.err_msg.?.msg);
            return;
        },
        error.OutOfMemory, error.InvalidInstruction => |e| {
            try writer.writeAll(switch (e) {
                error.OutOfMemory => "Out of memory",
                error.InvalidInstruction => "CodeGen failed to find a viable instruction.",
            });
            return;
        },
        else => |e| return e,
    }).insts) |lowered_inst| {
        if (!first) try writer.writeAll("\ndebug(wip_mir): ");
        try writer.print("  | {}", .{lowered_inst});
        first = false;
    }
}
fn fmtWipMir(func: *Func, inst: Mir.Inst.Index) std.fmt.Formatter(formatWipMir) {
    return .{ .data = .{ .func = func, .inst = inst } };
}

const FormatDeclData = struct {
    mod: *Zcu,
    decl_index: InternPool.DeclIndex,
};
fn formatDecl(
    data: FormatDeclData,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) @TypeOf(writer).Error!void {
    try data.mod.declPtr(data.decl_index).renderFullyQualifiedName(data.mod, writer);
}
fn fmtDecl(func: *Func, decl_index: InternPool.DeclIndex) std.fmt.Formatter(formatDecl) {
    return .{ .data = .{
        .mod = func.bin_file.comp.module.?,
        .decl_index = decl_index,
    } };
}

const FormatAirData = struct {
    func: *Func,
    inst: Air.Inst.Index,
};
fn formatAir(
    data: FormatAirData,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) @TypeOf(writer).Error!void {
    @import("../../print_air.zig").dumpInst(
        data.inst,
        data.func.bin_file.comp.module.?,
        data.func.air,
        data.func.liveness,
    );
}
fn fmtAir(func: *Func, inst: Air.Inst.Index) std.fmt.Formatter(formatAir) {
    return .{ .data = .{ .func = func, .inst = inst } };
}

const FormatTrackingData = struct {
    func: *Func,
};
fn formatTracking(
    data: FormatTrackingData,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) @TypeOf(writer).Error!void {
    var it = data.func.inst_tracking.iterator();
    while (it.next()) |entry| try writer.print("\n%{d} = {}", .{ entry.key_ptr.*, entry.value_ptr.* });
}
fn fmtTracking(func: *Func) std.fmt.Formatter(formatTracking) {
    return .{ .data = .{ .func = func } };
}

fn addInst(func: *Func, inst: Mir.Inst) error{OutOfMemory}!Mir.Inst.Index {
    const gpa = func.gpa;
    try func.mir_instructions.ensureUnusedCapacity(gpa, 1);
    const result_index: Mir.Inst.Index = @intCast(func.mir_instructions.len);
    func.mir_instructions.appendAssumeCapacity(inst);
    if (inst.tag != .pseudo or switch (inst.ops) {
        else => true,
        .pseudo_dbg_prologue_end,
        .pseudo_dbg_line_column,
        .pseudo_dbg_epilogue_begin,
        .pseudo_store_rm,
        .pseudo_load_rm,
        .pseudo_lea_rm,
        .pseudo_mv,
        .pseudo_dead,
        => false,
    }) wip_mir_log.debug("{}", .{func.fmtWipMir(result_index)}) else wip_mir_log.debug("  | uses-mem", .{});
    return result_index;
}

fn addNop(func: *Func) error{OutOfMemory}!Mir.Inst.Index {
    return func.addInst(.{
        .tag = .nop,
        .ops = .none,
        .data = undefined,
    });
}

fn addPseudoNone(func: *Func, ops: Mir.Inst.Ops) !void {
    _ = try func.addInst(.{
        .tag = .pseudo,
        .ops = ops,
        .data = undefined,
    });
}

fn addPseudo(func: *Func, ops: Mir.Inst.Ops) !Mir.Inst.Index {
    return func.addInst(.{
        .tag = .pseudo,
        .ops = ops,
        .data = undefined,
    });
}

pub fn addExtra(func: *Func, extra: anytype) Allocator.Error!u32 {
    const fields = std.meta.fields(@TypeOf(extra));
    try func.mir_extra.ensureUnusedCapacity(func.gpa, fields.len);
    return func.addExtraAssumeCapacity(extra);
}

pub fn addExtraAssumeCapacity(func: *Func, extra: anytype) u32 {
    const fields = std.meta.fields(@TypeOf(extra));
    const result: u32 = @intCast(func.mir_extra.items.len);
    inline for (fields) |field| {
        func.mir_extra.appendAssumeCapacity(switch (field.type) {
            u32 => @field(extra, field.name),
            i32 => @bitCast(@field(extra, field.name)),
            else => @compileError("bad field type"),
        });
    }
    return result;
}

const required_features = [_]Target.riscv.Feature{
    .d,
    .m,
};

fn gen(func: *Func) !void {
    const mod = func.bin_file.comp.module.?;
    const fn_info = mod.typeToFunc(func.fn_type).?;

    inline for (required_features) |feature| {
        if (!func.hasFeature(feature)) {
            return func.fail(
                "target missing required feature {s}",
                .{@tagName(feature)},
            );
        }
    }

    if (fn_info.cc != .Naked) {
        try func.addPseudoNone(.pseudo_dbg_prologue_end);

        const backpatch_stack_alloc = try func.addPseudo(.pseudo_dead);
        const backpatch_ra_spill = try func.addPseudo(.pseudo_dead);
        const backpatch_fp_spill = try func.addPseudo(.pseudo_dead);
        const backpatch_fp_add = try func.addPseudo(.pseudo_dead);
        const backpatch_spill_callee_preserved_regs = try func.addPseudo(.pseudo_dead);

        switch (func.ret_mcv.long) {
            .none, .unreach => {},
            .indirect => {
                // The address where to store the return value for the caller is in a
                // register which the callee is free to clobber. Therefore, we purposely
                // spill it to stack immediately.
                const frame_index = try func.allocFrameIndex(FrameAlloc.initSpill(Type.usize, mod));
                try func.genSetMem(
                    .{ .frame = frame_index },
                    0,
                    Type.usize,
                    func.ret_mcv.long.address().offset(-func.ret_mcv.short.indirect.off),
                );
                func.ret_mcv.long = .{ .load_frame = .{ .index = frame_index } };
                tracking_log.debug("spill {} to {}", .{ func.ret_mcv.long, frame_index });
            },
            else => unreachable,
        }

        try func.genBody(func.air.getMainBody());

        for (func.exitlude_jump_relocs.items) |jmp_reloc| {
            func.mir_instructions.items(.data)[jmp_reloc].inst =
                @intCast(func.mir_instructions.len);
        }

        try func.addPseudoNone(.pseudo_dbg_epilogue_begin);

        const backpatch_restore_callee_preserved_regs = try func.addPseudo(.pseudo_dead);
        const backpatch_ra_restore = try func.addPseudo(.pseudo_dead);
        const backpatch_fp_restore = try func.addPseudo(.pseudo_dead);
        const backpatch_stack_alloc_restore = try func.addPseudo(.pseudo_dead);
        try func.addPseudoNone(.pseudo_ret);

        const frame_layout = try func.computeFrameLayout();
        const need_save_reg = frame_layout.save_reg_list.count() > 0;

        func.mir_instructions.set(backpatch_stack_alloc, .{
            .tag = .addi,
            .ops = .rri,
            .data = .{ .i_type = .{
                .rd = .sp,
                .rs1 = .sp,
                .imm12 = Immediate.s(-@as(i32, @intCast(frame_layout.stack_adjust))),
            } },
        });
        func.mir_instructions.set(backpatch_ra_spill, .{
            .tag = .pseudo,
            .ops = .pseudo_store_rm,
            .data = .{ .rm = .{
                .r = .ra,
                .m = .{
                    .base = .{ .frame = .ret_addr },
                    .mod = .{ .size = .dword, .unsigned = false },
                },
            } },
        });
        func.mir_instructions.set(backpatch_ra_restore, .{
            .tag = .pseudo,
            .ops = .pseudo_load_rm,
            .data = .{ .rm = .{
                .r = .ra,
                .m = .{
                    .base = .{ .frame = .ret_addr },
                    .mod = .{ .size = .dword, .unsigned = false },
                },
            } },
        });
        func.mir_instructions.set(backpatch_fp_spill, .{
            .tag = .pseudo,
            .ops = .pseudo_store_rm,
            .data = .{ .rm = .{
                .r = .s0,
                .m = .{
                    .base = .{ .frame = .base_ptr },
                    .mod = .{ .size = .dword, .unsigned = false },
                },
            } },
        });
        func.mir_instructions.set(backpatch_fp_restore, .{
            .tag = .pseudo,
            .ops = .pseudo_load_rm,
            .data = .{ .rm = .{
                .r = .s0,
                .m = .{
                    .base = .{ .frame = .base_ptr },
                    .mod = .{ .size = .dword, .unsigned = false },
                },
            } },
        });
        func.mir_instructions.set(backpatch_fp_add, .{
            .tag = .addi,
            .ops = .rri,
            .data = .{ .i_type = .{
                .rd = .s0,
                .rs1 = .sp,
                .imm12 = Immediate.s(@intCast(frame_layout.stack_adjust)),
            } },
        });
        func.mir_instructions.set(backpatch_stack_alloc_restore, .{
            .tag = .addi,
            .ops = .rri,
            .data = .{ .i_type = .{
                .rd = .sp,
                .rs1 = .sp,
                .imm12 = Immediate.s(@intCast(frame_layout.stack_adjust)),
            } },
        });

        if (need_save_reg) {
            func.mir_instructions.set(backpatch_spill_callee_preserved_regs, .{
                .tag = .pseudo,
                .ops = .pseudo_spill_regs,
                .data = .{ .reg_list = frame_layout.save_reg_list },
            });

            func.mir_instructions.set(backpatch_restore_callee_preserved_regs, .{
                .tag = .pseudo,
                .ops = .pseudo_restore_regs,
                .data = .{ .reg_list = frame_layout.save_reg_list },
            });
        }
    } else {
        try func.addPseudoNone(.pseudo_dbg_prologue_end);
        try func.genBody(func.air.getMainBody());
        try func.addPseudoNone(.pseudo_dbg_epilogue_begin);
    }

    // Drop them off at the rbrace.
    _ = try func.addInst(.{
        .tag = .pseudo,
        .ops = .pseudo_dbg_line_column,
        .data = .{ .pseudo_dbg_line_column = .{
            .line = func.end_di_line,
            .column = func.end_di_column,
        } },
    });
}

fn genBody(func: *Func, body: []const Air.Inst.Index) InnerError!void {
    const zcu = func.bin_file.comp.module.?;
    const ip = &zcu.intern_pool;
    const air_tags = func.air.instructions.items(.tag);

    for (body) |inst| {
        if (func.liveness.isUnused(inst) and !func.air.mustLower(inst, ip)) continue;
        wip_mir_log.debug("{}", .{func.fmtAir(inst)});
        verbose_tracking_log.debug("{}", .{func.fmtTracking()});

        const old_air_bookkeeping = func.air_bookkeeping;
        try func.inst_tracking.ensureUnusedCapacity(func.gpa, 1);
        const tag: Air.Inst.Tag = air_tags[@intFromEnum(inst)];
        switch (tag) {
            // zig fmt: off
            .add,
            .add_wrap,
            .sub,
            .sub_wrap,

            .mul,
            .mul_wrap,
            .div_trunc, 

            .shl, .shl_exact,
            .shr, .shr_exact,

            .bool_and,
            .bool_or,
            .bit_and,
            .bit_or,

            .xor,

            .min,
            .max,
            => try func.airBinOp(inst, tag),

                        
            .ptr_add,
            .ptr_sub => try func.airPtrArithmetic(inst, tag),

            .rem,
            .mod,
            .div_float, 
            .div_floor, 
            .div_exact,
            => return func.fail("TODO: {s}", .{@tagName(tag)}),

            .sqrt,
            .sin,
            .cos,
            .tan,
            .exp,
            .exp2,
            .log,
            .log2,
            .log10,
            .floor,
            .ceil,
            .round,
            .trunc_float,
            .neg,
            => try func.airUnaryMath(inst),

            .add_with_overflow => try func.airAddWithOverflow(inst),
            .sub_with_overflow => try func.airSubWithOverflow(inst),
            .mul_with_overflow => try func.airMulWithOverflow(inst),
            .shl_with_overflow => try func.airShlWithOverflow(inst),


            .add_sat         => try func.airAddSat(inst),
            .sub_sat         => try func.airSubSat(inst),
            .mul_sat         => try func.airMulSat(inst),
            .shl_sat         => try func.airShlSat(inst),

            .add_safe,
            .sub_safe,
            .mul_safe,
            => return func.fail("TODO implement safety_checked_instructions", .{}),

            .cmp_lt,
            .cmp_lte,
            .cmp_eq,
            .cmp_gte,
            .cmp_gt,
            .cmp_neq,
            => try func.airCmp(inst, tag),

            .cmp_vector => try func.airCmpVector(inst),
            .cmp_lt_errors_len => try func.airCmpLtErrorsLen(inst),

            .slice           => try func.airSlice(inst),
            .array_to_slice  => try func.airArrayToSlice(inst),

            .slice_ptr       => try func.airSlicePtr(inst),
            .slice_len       => try func.airSliceLen(inst),

            .alloc           => try func.airAlloc(inst),
            .ret_ptr         => try func.airRetPtr(inst),
            .arg             => try func.airArg(inst),
            .assembly        => try func.airAsm(inst),
            .bitcast         => try func.airBitCast(inst),
            .block           => try func.airBlock(inst),
            .br              => try func.airBr(inst),
            .trap            => try func.airTrap(),
            .breakpoint      => try func.airBreakpoint(),
            .ret_addr        => try func.airRetAddr(inst),
            .frame_addr      => try func.airFrameAddress(inst),
            .fence           => try func.airFence(),
            .cond_br         => try func.airCondBr(inst),
            .dbg_stmt        => try func.airDbgStmt(inst),
            .fptrunc         => try func.airFptrunc(inst),
            .fpext           => try func.airFpext(inst),
            .intcast         => try func.airIntCast(inst),
            .trunc           => try func.airTrunc(inst),
            .int_from_bool   => try func.airIntFromBool(inst),
            .is_non_null     => try func.airIsNonNull(inst),
            .is_non_null_ptr => try func.airIsNonNullPtr(inst),
            .is_null         => try func.airIsNull(inst),
            .is_null_ptr     => try func.airIsNullPtr(inst),
            .is_non_err      => try func.airIsNonErr(inst),
            .is_non_err_ptr  => try func.airIsNonErrPtr(inst),
            .is_err          => try func.airIsErr(inst),
            .is_err_ptr      => try func.airIsErrPtr(inst),
            .load            => try func.airLoad(inst),
            .loop            => try func.airLoop(inst),
            .not             => try func.airNot(inst),
            .int_from_ptr    => try func.airIntFromPtr(inst),
            .ret             => try func.airRet(inst, false),
            .ret_safe        => try func.airRet(inst, true),
            .ret_load        => try func.airRetLoad(inst),
            .store           => try func.airStore(inst, false),
            .store_safe      => try func.airStore(inst, true),
            .struct_field_ptr=> try func.airStructFieldPtr(inst),
            .struct_field_val=> try func.airStructFieldVal(inst),
            .float_from_int  => try func.airFloatFromInt(inst),
            .int_from_float  => try func.airIntFromFloat(inst),
            .cmpxchg_strong  => try func.airCmpxchg(inst),
            .cmpxchg_weak    => try func.airCmpxchg(inst),
            .atomic_rmw      => try func.airAtomicRmw(inst),
            .atomic_load     => try func.airAtomicLoad(inst),
            .memcpy          => try func.airMemcpy(inst),
            .memset          => try func.airMemset(inst, false),
            .memset_safe     => try func.airMemset(inst, true),
            .set_union_tag   => try func.airSetUnionTag(inst),
            .get_union_tag   => try func.airGetUnionTag(inst),
            .clz             => try func.airClz(inst),
            .ctz             => try func.airCtz(inst),
            .popcount        => try func.airPopcount(inst),
            .abs             => try func.airAbs(inst),
            .byte_swap       => try func.airByteSwap(inst),
            .bit_reverse     => try func.airBitReverse(inst),
            .tag_name        => try func.airTagName(inst),
            .error_name      => try func.airErrorName(inst),
            .splat           => try func.airSplat(inst),
            .select          => try func.airSelect(inst),
            .shuffle         => try func.airShuffle(inst),
            .reduce          => try func.airReduce(inst),
            .aggregate_init  => try func.airAggregateInit(inst),
            .union_init      => try func.airUnionInit(inst),
            .prefetch        => try func.airPrefetch(inst),
            .mul_add         => try func.airMulAdd(inst),
            .addrspace_cast  => return func.fail("TODO: addrspace_cast", .{}),

            .@"try"          =>  try func.airTry(inst),
            .try_ptr         =>  return func.fail("TODO: try_ptr", .{}),

            .dbg_var_ptr,
            .dbg_var_val,
            => try func.airDbgVar(inst),

            .dbg_inline_block => try func.airDbgInlineBlock(inst),

            .call              => try func.airCall(inst, .auto),
            .call_always_tail  => try func.airCall(inst, .always_tail),
            .call_never_tail   => try func.airCall(inst, .never_tail),
            .call_never_inline => try func.airCall(inst, .never_inline),

            .atomic_store_unordered => try func.airAtomicStore(inst, .unordered),
            .atomic_store_monotonic => try func.airAtomicStore(inst, .monotonic),
            .atomic_store_release   => try func.airAtomicStore(inst, .release),
            .atomic_store_seq_cst   => try func.airAtomicStore(inst, .seq_cst),
            .struct_field_ptr_index_0 => try func.airStructFieldPtrIndex(inst, 0),
            .struct_field_ptr_index_1 => try func.airStructFieldPtrIndex(inst, 1),
            .struct_field_ptr_index_2 => try func.airStructFieldPtrIndex(inst, 2),
            .struct_field_ptr_index_3 => try func.airStructFieldPtrIndex(inst, 3),

            .field_parent_ptr => try func.airFieldParentPtr(inst),

            .switch_br       => try func.airSwitchBr(inst),

            .ptr_slice_len_ptr => try func.airPtrSliceLenPtr(inst),
            .ptr_slice_ptr_ptr => try func.airPtrSlicePtrPtr(inst),

            .array_elem_val      => try func.airArrayElemVal(inst),
            
            .slice_elem_val      => try func.airSliceElemVal(inst),
            .slice_elem_ptr      => try func.airSliceElemPtr(inst),

            .ptr_elem_val        => try func.airPtrElemVal(inst),
            .ptr_elem_ptr        => try func.airPtrElemPtr(inst),

            .inferred_alloc, .inferred_alloc_comptime => unreachable,
            .unreach  => func.finishAirBookkeeping(),

            .optional_payload           => try func.airOptionalPayload(inst),
            .optional_payload_ptr       => try func.airOptionalPayloadPtr(inst),
            .optional_payload_ptr_set   => try func.airOptionalPayloadPtrSet(inst),
            .unwrap_errunion_err        => try func.airUnwrapErrErr(inst),
            .unwrap_errunion_payload    => try func.airUnwrapErrPayload(inst),
            .unwrap_errunion_err_ptr    => try func.airUnwrapErrErrPtr(inst),
            .unwrap_errunion_payload_ptr=> try func.airUnwrapErrPayloadPtr(inst),
            .errunion_payload_ptr_set   => try func.airErrUnionPayloadPtrSet(inst),
            .err_return_trace           => try func.airErrReturnTrace(inst),
            .set_err_return_trace       => try func.airSetErrReturnTrace(inst),
            .save_err_return_trace_index=> try func.airSaveErrReturnTraceIndex(inst),

            .wrap_optional         => try func.airWrapOptional(inst),
            .wrap_errunion_payload => try func.airWrapErrUnionPayload(inst),
            .wrap_errunion_err     => try func.airWrapErrUnionErr(inst),

            .add_optimized,
            .sub_optimized,
            .mul_optimized,
            .div_float_optimized,
            .div_trunc_optimized,
            .div_floor_optimized,
            .div_exact_optimized,
            .rem_optimized,
            .mod_optimized,
            .neg_optimized,
            .cmp_lt_optimized,
            .cmp_lte_optimized,
            .cmp_eq_optimized,
            .cmp_gte_optimized,
            .cmp_gt_optimized,
            .cmp_neq_optimized,
            .cmp_vector_optimized,
            .reduce_optimized,
            .int_from_float_optimized,
            => return func.fail("TODO implement optimized float mode", .{}),

            .is_named_enum_value => return func.fail("TODO implement is_named_enum_value", .{}),
            .error_set_has_value => return func.fail("TODO implement error_set_has_value", .{}),
            .vector_store_elem => return func.fail("TODO implement vector_store_elem", .{}),

            .c_va_arg => return func.fail("TODO implement c_va_arg", .{}),
            .c_va_copy => return func.fail("TODO implement c_va_copy", .{}),
            .c_va_end => return func.fail("TODO implement c_va_end", .{}),
            .c_va_start => return func.fail("TODO implement c_va_start", .{}),

            .wasm_memory_size => unreachable,
            .wasm_memory_grow => unreachable,

            .work_item_id => unreachable,
            .work_group_size => unreachable,
            .work_group_id => unreachable,
            // zig fmt: on
        }

        assert(!func.register_manager.lockedRegsExist());

        if (std.debug.runtime_safety) {
            if (func.air_bookkeeping < old_air_bookkeeping + 1) {
                std.debug.panic("in codegen.zig, handling of AIR instruction %{d} ('{}') did not do proper bookkeeping. Look for a missing call to finishAir.", .{ inst, air_tags[@intFromEnum(inst)] });
            }

            { // check consistency of tracked registers
                var it = func.register_manager.free_registers.iterator(.{ .kind = .unset });
                while (it.next()) |index| {
                    const tracked_inst = func.register_manager.registers[index];
                    tracking_log.debug("tracked inst: {}", .{tracked_inst});
                    const tracking = func.getResolvedInstValue(tracked_inst);
                    for (tracking.getRegs()) |reg| {
                        if (RegisterManager.indexOfRegIntoTracked(reg).? == index) break;
                    } else return std.debug.panic(
                        \\%{} takes up these regs: {any}, however these regs {any}, don't use it
                    , .{ tracked_inst, tracking.getRegs(), RegisterManager.regAtTrackedIndex(@intCast(index)) });
                }
            }
        }
    }
    verbose_tracking_log.debug("{}", .{func.fmtTracking()});
}

fn getValue(func: *Func, value: MCValue, inst: ?Air.Inst.Index) !void {
    for (value.getRegs()) |reg| try func.register_manager.getReg(reg, inst);
}

fn getValueIfFree(func: *Func, value: MCValue, inst: ?Air.Inst.Index) void {
    for (value.getRegs()) |reg| if (func.register_manager.isRegFree(reg))
        func.register_manager.getRegAssumeFree(reg, inst);
}

fn freeValue(func: *Func, value: MCValue) !void {
    switch (value) {
        .register => |reg| func.register_manager.freeReg(reg),
        .register_pair => |regs| for (regs) |reg| func.register_manager.freeReg(reg),
        .register_offset => |reg_off| func.register_manager.freeReg(reg_off.reg),
        else => {}, // TODO process stack allocation death
    }
}

fn feed(func: *Func, bt: *Liveness.BigTomb, operand: Air.Inst.Ref) !void {
    if (bt.feed()) if (operand.toIndex()) |inst| {
        log.debug("feed inst: %{}", .{inst});
        try func.processDeath(inst);
    };
}

/// Asserts there is already capacity to insert into top branch inst_table.
fn processDeath(func: *Func, inst: Air.Inst.Index) !void {
    try func.inst_tracking.getPtr(inst).?.die(func, inst);
}

/// Called when there are no operands, and the instruction is always unreferenced.
fn finishAirBookkeeping(func: *Func) void {
    if (std.debug.runtime_safety) {
        func.air_bookkeeping += 1;
    }
}

fn finishAirResult(func: *Func, inst: Air.Inst.Index, result: MCValue) void {
    if (func.liveness.isUnused(inst)) switch (result) {
        .none, .dead, .unreach => {},
        else => unreachable, // Why didn't the result die?
    } else {
        tracking_log.debug("%{d} => {} (birth)", .{ inst, result });
        func.inst_tracking.putAssumeCapacityNoClobber(inst, InstTracking.init(result));
        // In some cases, an operand may be reused as the result.
        // If that operand died and was a register, it was freed by
        // processDeath, so we have to "re-allocate" the register.
        func.getValueIfFree(result, inst);
    }
    func.finishAirBookkeeping();
}

fn finishAir(
    func: *Func,
    inst: Air.Inst.Index,
    result: MCValue,
    operands: [Liveness.bpi - 1]Air.Inst.Ref,
) !void {
    var tomb_bits = func.liveness.getTombBits(inst);
    for (operands) |op| {
        const dies = @as(u1, @truncate(tomb_bits)) != 0;
        tomb_bits >>= 1;
        if (!dies) continue;
        try func.processDeath(op.toIndexAllowNone() orelse continue);
    }
    func.finishAirResult(inst, result);
}

const FrameLayout = struct {
    stack_adjust: u32,
    save_reg_list: Mir.RegisterList,
};

fn setFrameLoc(
    func: *Func,
    frame_index: FrameIndex,
    base: Register,
    offset: *i32,
    comptime aligned: bool,
) void {
    const frame_i = @intFromEnum(frame_index);
    if (aligned) {
        const alignment: InternPool.Alignment = func.frame_allocs.items(.abi_align)[frame_i];
        offset.* = if (math.sign(offset.*) < 0)
            -1 * @as(i32, @intCast(alignment.backward(@intCast(@abs(offset.*)))))
        else
            @intCast(alignment.forward(@intCast(@abs(offset.*))));
    }
    func.frame_locs.set(frame_i, .{ .base = base, .disp = offset.* });
    offset.* += func.frame_allocs.items(.abi_size)[frame_i];
}

fn computeFrameLayout(func: *Func) !FrameLayout {
    const frame_allocs_len = func.frame_allocs.len;
    try func.frame_locs.resize(func.gpa, frame_allocs_len);
    const stack_frame_order = try func.gpa.alloc(FrameIndex, frame_allocs_len - FrameIndex.named_count);
    defer func.gpa.free(stack_frame_order);

    const frame_size = func.frame_allocs.items(.abi_size);
    const frame_align = func.frame_allocs.items(.abi_align);

    for (stack_frame_order, FrameIndex.named_count..) |*frame_order, frame_index|
        frame_order.* = @enumFromInt(frame_index);

    {
        const SortContext = struct {
            frame_align: @TypeOf(frame_align),
            pub fn lessThan(context: @This(), lhs: FrameIndex, rhs: FrameIndex) bool {
                return context.frame_align[@intFromEnum(lhs)].compare(.gt, context.frame_align[@intFromEnum(rhs)]);
            }
        };
        const sort_context = SortContext{ .frame_align = frame_align };
        mem.sort(FrameIndex, stack_frame_order, sort_context, SortContext.lessThan);
    }

    var save_reg_list = Mir.RegisterList{};
    for (abi.Registers.all_preserved) |reg| {
        if (func.register_manager.isRegAllocated(reg)) {
            save_reg_list.push(&abi.Registers.all_preserved, reg);
        }
    }

    const total_alloc_size: i32 = blk: {
        var i: i32 = 0;
        for (stack_frame_order) |frame_index| {
            i += frame_size[@intFromEnum(frame_index)];
        }
        break :blk i;
    };
    const saved_reg_size = save_reg_list.size();

    frame_size[@intFromEnum(FrameIndex.spill_frame)] = @intCast(saved_reg_size);

    // The total frame size is calculated by the amount of s registers you need to save * 8, as each
    // register is 8 bytes, the total allocation sizes, and 16 more register for the spilled ra and s0
    // register. Finally we align the frame size to the align of the base pointer.
    const args_frame_size = frame_size[@intFromEnum(FrameIndex.args_frame)];
    const spill_frame_size = frame_size[@intFromEnum(FrameIndex.spill_frame)];
    const call_frame_size = frame_size[@intFromEnum(FrameIndex.call_frame)];

    // TODO: this 64 should be a 16, but we were clobbering the top and bottom of the frame.
    // maybe everything can go from the bottom?
    const acc_frame_size: i32 = std.mem.alignForward(
        i32,
        total_alloc_size + 64 + args_frame_size + spill_frame_size + call_frame_size,
        @intCast(frame_align[@intFromEnum(FrameIndex.base_ptr)].toByteUnits().?),
    );
    log.debug("frame size: {}", .{acc_frame_size});

    // store the ra at total_size - 8, so it's the very first thing in the stack
    // relative to the fp
    func.frame_locs.set(
        @intFromEnum(FrameIndex.ret_addr),
        .{ .base = .sp, .disp = acc_frame_size - 8 },
    );
    func.frame_locs.set(
        @intFromEnum(FrameIndex.base_ptr),
        .{ .base = .sp, .disp = acc_frame_size - 16 },
    );

    // now we grow the stack frame from the bottom of total frame in order to
    // not need to know the size of the first allocation. Stack offsets point at the "bottom"
    // of variables.
    var s0_offset: i32 = -acc_frame_size;
    func.setFrameLoc(.stack_frame, .s0, &s0_offset, true);
    for (stack_frame_order) |frame_index| func.setFrameLoc(frame_index, .s0, &s0_offset, true);
    func.setFrameLoc(.args_frame, .s0, &s0_offset, true);
    func.setFrameLoc(.call_frame, .s0, &s0_offset, true);
    func.setFrameLoc(.spill_frame, .s0, &s0_offset, true);

    return .{
        .stack_adjust = @intCast(acc_frame_size),
        .save_reg_list = save_reg_list,
    };
}

fn ensureProcessDeathCapacity(func: *Func, additional_count: usize) !void {
    const table = &func.branch_stack.items[func.branch_stack.items.len - 1].inst_table;
    try table.ensureUnusedCapacity(func.gpa, additional_count);
}

fn memSize(func: *Func, ty: Type) Memory.Size {
    const mod = func.bin_file.comp.module.?;
    return switch (ty.zigTypeTag(mod)) {
        .Float => Memory.Size.fromBitSize(ty.floatBits(func.target.*)),
        else => Memory.Size.fromByteSize(ty.abiSize(mod)),
    };
}

fn splitType(func: *Func, ty: Type) ![2]Type {
    const zcu = func.bin_file.comp.module.?;
    const classes = mem.sliceTo(&abi.classifySystem(ty, zcu), .none);
    var parts: [2]Type = undefined;
    if (classes.len == 2) for (&parts, classes, 0..) |*part, class, part_i| {
        part.* = switch (class) {
            .integer => switch (part_i) {
                0 => Type.u64,
                1 => part: {
                    const elem_size = ty.abiAlignment(zcu).minStrict(.@"8").toByteUnits().?;
                    const elem_ty = try zcu.intType(.unsigned, @intCast(elem_size * 8));
                    break :part switch (@divExact(ty.abiSize(zcu) - 8, elem_size)) {
                        1 => elem_ty,
                        else => |len| try zcu.arrayType(.{ .len = len, .child = elem_ty.toIntern() }),
                    };
                },
                else => unreachable,
            },
            else => return func.fail("TODO: splitType class {}", .{class}),
        };
    } else if (parts[0].abiSize(zcu) + parts[1].abiSize(zcu) == ty.abiSize(zcu)) return parts;
    return func.fail("TODO implement splitType for {}", .{ty.fmt(zcu)});
}

/// Truncates the value in the register in place.
/// Clobbers any remaining bits.
fn truncateRegister(func: *Func, ty: Type, reg: Register) !void {
    const mod = func.bin_file.comp.module.?;
    const int_info = if (ty.isAbiInt(mod)) ty.intInfo(mod) else std.builtin.Type.Int{
        .signedness = .unsigned,
        .bits = @intCast(ty.bitSize(mod)),
    };
    const shift = math.cast(u6, 64 - int_info.bits % 64) orelse return;
    switch (int_info.signedness) {
        .signed => {
            _ = try func.addInst(.{
                .tag = .slli,
                .ops = .rri,
                .data = .{
                    .i_type = .{
                        .rd = reg,
                        .rs1 = reg,
                        .imm12 = Immediate.u(shift),
                    },
                },
            });
            _ = try func.addInst(.{
                .tag = .srai,
                .ops = .rri,
                .data = .{
                    .i_type = .{
                        .rd = reg,
                        .rs1 = reg,
                        .imm12 = Immediate.u(shift),
                    },
                },
            });
        },
        .unsigned => {
            const mask = ~@as(u64, 0) >> shift;
            if (mask < 256) {
                _ = try func.addInst(.{
                    .tag = .andi,
                    .ops = .rri,
                    .data = .{
                        .i_type = .{
                            .rd = reg,
                            .rs1 = reg,
                            .imm12 = Immediate.u(@intCast(mask)),
                        },
                    },
                });
            } else {
                _ = try func.addInst(.{
                    .tag = .slli,
                    .ops = .rri,
                    .data = .{
                        .i_type = .{
                            .rd = reg,
                            .rs1 = reg,
                            .imm12 = Immediate.u(shift),
                        },
                    },
                });
                _ = try func.addInst(.{
                    .tag = .srli,
                    .ops = .rri,
                    .data = .{
                        .i_type = .{
                            .rd = reg,
                            .rs1 = reg,
                            .imm12 = Immediate.u(shift),
                        },
                    },
                });
            }
        },
    }
}

fn symbolIndex(func: *Func) !u32 {
    const zcu = func.bin_file.comp.module.?;
    const decl_index = zcu.funcOwnerDeclIndex(func.func_index);
    return switch (func.bin_file.tag) {
        .elf => blk: {
            const elf_file = func.bin_file.cast(link.File.Elf).?;
            const atom_index = try elf_file.zigObjectPtr().?.getOrCreateMetadataForDecl(elf_file, decl_index);
            break :blk atom_index;
        },
        else => return func.fail("TODO symbolIndex {s}", .{@tagName(func.bin_file.tag)}),
    };
}

fn allocFrameIndex(func: *Func, alloc: FrameAlloc) !FrameIndex {
    const frame_allocs_slice = func.frame_allocs.slice();
    const frame_size = frame_allocs_slice.items(.abi_size);
    const frame_align = frame_allocs_slice.items(.abi_align);

    const stack_frame_align = &frame_align[@intFromEnum(FrameIndex.stack_frame)];
    stack_frame_align.* = stack_frame_align.max(alloc.abi_align);

    for (func.free_frame_indices.keys(), 0..) |frame_index, free_i| {
        const abi_size = frame_size[@intFromEnum(frame_index)];
        if (abi_size != alloc.abi_size) continue;
        const abi_align = &frame_align[@intFromEnum(frame_index)];
        abi_align.* = abi_align.max(alloc.abi_align);

        _ = func.free_frame_indices.swapRemoveAt(free_i);
        return frame_index;
    }
    const frame_index: FrameIndex = @enumFromInt(func.frame_allocs.len);
    try func.frame_allocs.append(func.gpa, alloc);
    log.debug("allocated frame {}", .{frame_index});
    return frame_index;
}

/// Use a pointer instruction as the basis for allocating stack memory.
fn allocMemPtr(func: *Func, inst: Air.Inst.Index) !FrameIndex {
    const zcu = func.bin_file.comp.module.?;
    const ptr_ty = func.typeOfIndex(inst);
    const val_ty = ptr_ty.childType(zcu);
    return func.allocFrameIndex(FrameAlloc.init(.{
        .size = math.cast(u32, val_ty.abiSize(zcu)) orelse {
            return func.fail("type '{}' too big to fit into stack frame", .{val_ty.fmt(zcu)});
        },
        .alignment = ptr_ty.ptrAlignment(zcu).max(.@"1"),
    }));
}

fn typeRegClass(func: *Func, ty: Type) abi.RegisterClass {
    const zcu = func.bin_file.comp.module.?;
    return switch (ty.zigTypeTag(zcu)) {
        .Float => .float,
        .Vector => @panic("TODO: typeRegClass for Vectors"),
        inline else => .int,
    };
}

fn regGeneralClassForType(func: *Func, ty: Type) RegisterManager.RegisterBitSet {
    const zcu = func.bin_file.comp.module.?;
    return switch (ty.zigTypeTag(zcu)) {
        .Float => abi.Registers.Float.general_purpose,
        .Vector => @panic("TODO: regGeneralClassForType for Vectors"),
        else => abi.Registers.Integer.general_purpose,
    };
}

fn regTempClassForType(func: *Func, ty: Type) RegisterManager.RegisterBitSet {
    const zcu = func.bin_file.comp.module.?;
    return switch (ty.zigTypeTag(zcu)) {
        .Float => abi.Registers.Float.temporary,
        .Vector => @panic("TODO: regTempClassForType for Vectors"),
        else => abi.Registers.Integer.temporary,
    };
}

fn allocRegOrMem(func: *Func, elem_ty: Type, inst: ?Air.Inst.Index, reg_ok: bool) !MCValue {
    const zcu = func.bin_file.comp.module.?;

    const abi_size = math.cast(u32, elem_ty.abiSize(zcu)) orelse {
        return func.fail("type '{}' too big to fit into stack frame", .{elem_ty.fmt(zcu)});
    };

    const min_size: u32 = switch (elem_ty.zigTypeTag(zcu)) {
        .Float => 4,
        .Vector => @panic("allocRegOrMem Vector"),
        else => 8,
    };

    if (reg_ok and abi_size <= min_size) {
        if (func.register_manager.tryAllocReg(inst, func.regGeneralClassForType(elem_ty))) |reg| {
            return .{ .register = reg };
        }
    }

    const frame_index = try func.allocFrameIndex(FrameAlloc.initSpill(elem_ty, zcu));
    return .{ .load_frame = .{ .index = frame_index } };
}

/// Allocates a register from the general purpose set and returns the Register and the Lock.
///
/// Up to the caller to unlock the register later.
fn allocReg(func: *Func, reg_class: abi.RegisterClass) !struct { Register, RegisterLock } {
    if (reg_class == .float and !func.hasFeature(.f))
        std.debug.panic("allocReg class == float where F isn't enabled", .{});

    const class = switch (reg_class) {
        .int => abi.Registers.Integer.general_purpose,
        .float => abi.Registers.Float.general_purpose,
    };

    const reg = try func.register_manager.allocReg(null, class);
    const lock = func.register_manager.lockRegAssumeUnused(reg);
    return .{ reg, lock };
}

/// Similar to `allocReg` but will copy the MCValue into the Register unless `operand` is already
/// a register, in which case it will return a possible lock to that register.
fn promoteReg(func: *Func, ty: Type, operand: MCValue) !struct { Register, ?RegisterLock } {
    if (operand == .register) {
        const op_reg = operand.register;
        return .{ op_reg, func.register_manager.lockReg(operand.register) };
    }

    const reg, const lock = try func.allocReg(func.typeRegClass(ty));
    try func.genSetReg(ty, reg, operand);
    return .{ reg, lock };
}

fn elemOffset(func: *Func, index_ty: Type, index: MCValue, elem_size: u64) !Register {
    const reg: Register = blk: {
        switch (index) {
            .immediate => |imm| {
                // Optimisation: if index MCValue is an immediate, we can multiply in `comptime`
                // and set the register directly to the scaled offset as an immediate.
                const reg = try func.register_manager.allocReg(null, func.regGeneralClassForType(index_ty));
                try func.genSetReg(index_ty, reg, .{ .immediate = imm * elem_size });
                break :blk reg;
            },
            else => {
                const reg = try func.copyToTmpRegister(index_ty, index);
                const lock = func.register_manager.lockRegAssumeUnused(reg);
                defer func.register_manager.unlockReg(lock);

                const result_reg, const result_lock = try func.allocReg(.int);
                defer func.register_manager.unlockReg(result_lock);

                try func.genBinOp(
                    .mul,
                    .{ .register = reg },
                    index_ty,
                    .{ .immediate = elem_size },
                    index_ty,
                    result_reg,
                );

                break :blk result_reg;
            },
        }
    };
    return reg;
}

pub fn spillInstruction(func: *Func, reg: Register, inst: Air.Inst.Index) !void {
    const tracking = func.inst_tracking.getPtr(inst) orelse return;
    for (tracking.getRegs()) |tracked_reg| {
        if (tracked_reg.id() == reg.id()) break;
    } else unreachable; // spilled reg not tracked with spilled instruciton
    try tracking.spill(func, inst);
    try tracking.trackSpill(func, inst);
}

/// Copies a value to a register without tracking the register. The register is not considered
/// allocated. A second call to `copyToTmpRegister` may return the same register.
/// This can have a side effect of spilling instructions to the stack to free up a register.
fn copyToTmpRegister(func: *Func, ty: Type, mcv: MCValue) !Register {
    log.debug("copyToTmpRegister ty: {}", .{ty.fmt(func.bin_file.comp.module.?)});
    const reg = try func.register_manager.allocReg(null, func.regTempClassForType(ty));
    try func.genSetReg(ty, reg, mcv);
    return reg;
}

/// Allocates a new register and copies `mcv` into it.
/// `reg_owner` is the instruction that gets associated with the register in the register table.
/// This can have a side effect of spilling instructions to the stack to free up a register.
fn copyToNewRegister(func: *Func, reg_owner: Air.Inst.Index, mcv: MCValue) !MCValue {
    const ty = func.typeOfIndex(reg_owner);
    const reg = try func.register_manager.allocReg(reg_owner, func.regGeneralClassForType(ty));
    try func.genSetReg(func.typeOfIndex(reg_owner), reg, mcv);
    return MCValue{ .register = reg };
}

fn airAlloc(func: *Func, inst: Air.Inst.Index) !void {
    const result = MCValue{ .lea_frame = .{ .index = try func.allocMemPtr(inst) } };
    return func.finishAir(inst, result, .{ .none, .none, .none });
}

fn airRetPtr(func: *Func, inst: Air.Inst.Index) !void {
    const result: MCValue = switch (func.ret_mcv.long) {
        .none => .{ .lea_frame = .{ .index = try func.allocMemPtr(inst) } },
        .load_frame => .{ .register_offset = .{
            .reg = (try func.copyToNewRegister(
                inst,
                func.ret_mcv.long,
            )).register,
            .off = func.ret_mcv.short.indirect.off,
        } },
        else => |t| return func.fail("TODO: airRetPtr {s}", .{@tagName(t)}),
    };
    return func.finishAir(inst, result, .{ .none, .none, .none });
}

fn airFptrunc(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airFptrunc for {}", .{func.target.cpu.arch});
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airFpext(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airFpext for {}", .{func.target.cpu.arch});
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airIntCast(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const src_ty = func.typeOf(ty_op.operand);
    const dst_ty = func.typeOfIndex(inst);

    const result: MCValue = result: {
        const src_int_info = src_ty.intInfo(zcu);
        const dst_int_info = dst_ty.intInfo(zcu);

        const min_ty = if (dst_int_info.bits < src_int_info.bits) dst_ty else src_ty;

        const src_mcv = try func.resolveInst(ty_op.operand);

        const src_storage_bits: u16 = switch (src_mcv) {
            .register => 64,
            .load_frame => src_int_info.bits,
            else => return func.fail("airIntCast from {s}", .{@tagName(src_mcv)}),
        };

        const dst_mcv = if (dst_int_info.bits <= src_storage_bits and
            math.divCeil(u16, dst_int_info.bits, 64) catch unreachable ==
            math.divCeil(u32, src_storage_bits, 64) catch unreachable and
            func.reuseOperand(inst, ty_op.operand, 0, src_mcv)) src_mcv else dst: {
            const dst_mcv = try func.allocRegOrMem(dst_ty, inst, true);
            try func.genCopy(min_ty, dst_mcv, src_mcv);
            break :dst dst_mcv;
        };

        if (dst_int_info.bits <= src_int_info.bits)
            break :result dst_mcv;

        if (dst_int_info.bits > 64 or src_int_info.bits > 64)
            break :result null; // TODO

        break :result dst_mcv;
    } orelse return func.fail("TODO: implement airIntCast from {} to {}", .{
        src_ty.fmt(zcu), dst_ty.fmt(zcu),
    });

    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airTrunc(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    if (func.liveness.isUnused(inst))
        return func.finishAir(inst, .unreach, .{ ty_op.operand, .none, .none });

    const operand = try func.resolveInst(ty_op.operand);
    _ = operand;
    return func.fail("TODO implement trunc for {}", .{func.target.cpu.arch});
    // return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airIntFromBool(func: *Func, inst: Air.Inst.Index) !void {
    const un_op = func.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const operand = try func.resolveInst(un_op);
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else operand;
    return func.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airNot(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else result: {
        const zcu = func.bin_file.comp.module.?;

        const operand = try func.resolveInst(ty_op.operand);
        const ty = func.typeOf(ty_op.operand);

        switch (ty.zigTypeTag(zcu)) {
            .Bool => {
                const operand_reg = blk: {
                    if (operand == .register) break :blk operand.register;
                    break :blk try func.copyToTmpRegister(ty, operand);
                };

                const dst_reg: Register =
                    if (func.reuseOperand(inst, ty_op.operand, 0, operand) and operand == .register)
                    operand.register
                else
                    (try func.allocRegOrMem(func.typeOfIndex(inst), inst, true)).register;

                _ = try func.addInst(.{
                    .tag = .pseudo,
                    .ops = .pseudo_not,
                    .data = .{
                        .rr = .{
                            .rs = operand_reg,
                            .rd = dst_reg,
                        },
                    },
                });

                break :result .{ .register = dst_reg };
            },
            .Int => return func.fail("TODO: airNot ints", .{}),
            else => unreachable,
        }
    };
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airSlice(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const ty_pl = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const bin_op = func.air.extraData(Air.Bin, ty_pl.payload).data;

    const slice_ty = func.typeOfIndex(inst);
    const frame_index = try func.allocFrameIndex(FrameAlloc.initSpill(slice_ty, zcu));

    const ptr_ty = func.typeOf(bin_op.lhs);
    try func.genSetMem(.{ .frame = frame_index }, 0, ptr_ty, .{ .air_ref = bin_op.lhs });

    const len_ty = func.typeOf(bin_op.rhs);
    try func.genSetMem(
        .{ .frame = frame_index },
        @intCast(ptr_ty.abiSize(zcu)),
        len_ty,
        .{ .air_ref = bin_op.rhs },
    );

    const result = MCValue{ .load_frame = .{ .index = frame_index } };
    return func.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airBinOp(func: *Func, inst: Air.Inst.Index, tag: Air.Inst.Tag) !void {
    const zcu = func.bin_file.comp.module.?;
    const bin_op = func.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const dst_mcv = try func.binOp(inst, tag, bin_op.lhs, bin_op.rhs);

    const dst_ty = func.typeOfIndex(inst);
    if (dst_ty.isAbiInt(zcu)) {
        const abi_size: u32 = @intCast(dst_ty.abiSize(zcu));
        const bit_size: u32 = @intCast(dst_ty.bitSize(zcu));
        if (abi_size * 8 > bit_size) {
            const dst_lock = switch (dst_mcv) {
                .register => |dst_reg| func.register_manager.lockRegAssumeUnused(dst_reg),
                else => null,
            };
            defer if (dst_lock) |lock| func.register_manager.unlockReg(lock);

            if (dst_mcv.isRegister()) {
                try func.truncateRegister(dst_ty, dst_mcv.getReg().?);
            } else {
                const tmp_reg, const tmp_lock = try func.allocReg(.int);
                defer func.register_manager.unlockReg(tmp_lock);

                const hi_ty = try zcu.intType(.unsigned, @intCast((dst_ty.bitSize(zcu) - 1) % 64 + 1));
                const hi_mcv = dst_mcv.address().offset(@intCast(bit_size / 64 * 8)).deref();
                try func.genSetReg(hi_ty, tmp_reg, hi_mcv);
                try func.truncateRegister(dst_ty, tmp_reg);
                try func.genCopy(hi_ty, hi_mcv, .{ .register = tmp_reg });
            }
        }
    }

    return func.finishAir(inst, dst_mcv, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn binOp(
    func: *Func,
    maybe_inst: ?Air.Inst.Index,
    air_tag: Air.Inst.Tag,
    lhs_air: Air.Inst.Ref,
    rhs_air: Air.Inst.Ref,
) !MCValue {
    _ = maybe_inst;
    const zcu = func.bin_file.comp.module.?;
    const lhs_ty = func.typeOf(lhs_air);
    const rhs_ty = func.typeOf(rhs_air);

    if (lhs_ty.isRuntimeFloat()) libcall: {
        const float_bits = lhs_ty.floatBits(func.target.*);
        const type_needs_libcall = switch (float_bits) {
            16 => true,
            32, 64 => false,
            80, 128 => true,
            else => unreachable,
        };
        switch (air_tag) {
            .rem, .mod => {},
            else => if (!type_needs_libcall) break :libcall,
        }
        return func.fail("binOp libcall runtime-float ops", .{});
    }

    if (lhs_ty.bitSize(zcu) > 64) return func.fail("TODO: binOp >= 64 bits", .{});

    const lhs_mcv = try func.resolveInst(lhs_air);
    const rhs_mcv = try func.resolveInst(rhs_air);

    const class_for_dst_ty: abi.RegisterClass = switch (air_tag) {
        // will always return int register no matter the input
        .cmp_eq,
        .cmp_neq,
        .cmp_lt,
        .cmp_lte,
        .cmp_gt,
        .cmp_gte,
        => .int,

        else => func.typeRegClass(lhs_ty),
    };

    const dst_reg, const dst_lock = try func.allocReg(class_for_dst_ty);
    defer func.register_manager.unlockReg(dst_lock);

    try func.genBinOp(
        air_tag,
        lhs_mcv,
        lhs_ty,
        rhs_mcv,
        rhs_ty,
        dst_reg,
    );

    return .{ .register = dst_reg };
}

/// Does the same thing as binOp however is meant to be used internally to the backend.
///
/// The `dst_reg` argument is meant to be caller-locked. Asserts that the binOp result can be
/// fit into the register.
///
/// Assumes that the `dst_reg` class is correct.
fn genBinOp(
    func: *Func,
    tag: Air.Inst.Tag,
    lhs_mcv: MCValue,
    lhs_ty: Type,
    rhs_mcv: MCValue,
    rhs_ty: Type,
    dst_reg: Register,
) !void {
    const zcu = func.bin_file.comp.module.?;
    const bit_size = lhs_ty.bitSize(zcu);
    assert(bit_size <= 64);

    const is_unsigned = lhs_ty.isUnsignedInt(zcu);

    const lhs_reg, const maybe_lhs_lock = try func.promoteReg(lhs_ty, lhs_mcv);
    const rhs_reg, const maybe_rhs_lock = try func.promoteReg(rhs_ty, rhs_mcv);

    defer if (maybe_lhs_lock) |lock| func.register_manager.unlockReg(lock);
    defer if (maybe_rhs_lock) |lock| func.register_manager.unlockReg(lock);

    switch (tag) {
        .add,
        .add_wrap,
        .sub,
        .sub_wrap,
        .mul,
        .mul_wrap,
        => {
            if (!math.isPowerOfTwo(bit_size))
                return func.fail(
                    "TODO: genBinOp {s} non-pow 2, found {}",
                    .{ @tagName(tag), bit_size },
                );

            switch (lhs_ty.zigTypeTag(zcu)) {
                .Int => {
                    const mir_tag: Mir.Inst.Tag = switch (tag) {
                        .add, .add_wrap => switch (bit_size) {
                            8, 16, 64 => .add,
                            32 => .addw,
                            else => unreachable,
                        },
                        .sub, .sub_wrap => switch (bit_size) {
                            8, 16, 32 => .subw,
                            64 => .sub,
                            else => unreachable,
                        },
                        .mul, .mul_wrap => switch (bit_size) {
                            8, 16, 64 => .mul,
                            32 => .mulw,
                            else => unreachable,
                        },
                        else => unreachable,
                    };

                    _ = try func.addInst(.{
                        .tag = mir_tag,
                        .ops = .rrr,
                        .data = .{
                            .r_type = .{
                                .rd = dst_reg,
                                .rs1 = lhs_reg,
                                .rs2 = rhs_reg,
                            },
                        },
                    });

                    // truncate when the instruction is larger than the bit size.
                    switch (bit_size) {
                        8, 16 => try func.truncateRegister(lhs_ty, dst_reg),
                        32 => {}, // addw/subw affects the first 32-bits
                        64 => {}, // add/sub affects the entire register
                        else => unreachable,
                    }
                },
                .Float => {
                    const mir_tag: Mir.Inst.Tag = switch (tag) {
                        .add => switch (bit_size) {
                            32 => .fadds,
                            64 => .faddd,
                            else => unreachable,
                        },
                        .sub => switch (bit_size) {
                            32 => .fsubs,
                            64 => .fsubd,
                            else => unreachable,
                        },
                        .mul => switch (bit_size) {
                            32 => .fmuls,
                            64 => .fmuld,
                            else => unreachable,
                        },
                        else => unreachable,
                    };

                    _ = try func.addInst(.{
                        .tag = mir_tag,
                        .ops = .rrr,
                        .data = .{
                            .r_type = .{
                                .rd = dst_reg,
                                .rs1 = lhs_reg,
                                .rs2 = rhs_reg,
                            },
                        },
                    });
                },
                else => unreachable,
            }
        },

        .ptr_add,
        .ptr_sub,
        => {
            const tmp_reg = try func.copyToTmpRegister(rhs_ty, .{ .register = rhs_reg });
            const tmp_mcv = MCValue{ .register = tmp_reg };
            const tmp_lock = func.register_manager.lockRegAssumeUnused(tmp_reg);
            defer func.register_manager.unlockReg(tmp_lock);

            // RISC-V has no immediate mul, so we copy the size to a temporary register
            const elem_size = lhs_ty.elemType2(zcu).abiSize(zcu);
            const elem_size_reg = try func.copyToTmpRegister(Type.usize, .{ .immediate = elem_size });

            try func.genBinOp(
                .mul,
                tmp_mcv,
                rhs_ty,
                .{ .register = elem_size_reg },
                Type.usize,
                tmp_reg,
            );

            try func.genBinOp(
                switch (tag) {
                    .ptr_add => .add,
                    .ptr_sub => .sub,
                    else => unreachable,
                },
                lhs_mcv,
                Type.usize, // we know it's a pointer, so it'll be usize.
                tmp_mcv,
                Type.usize,
                dst_reg,
            );
        },

        .bit_and,
        .bit_or,
        .bool_and,
        .bool_or,
        => {
            _ = try func.addInst(.{
                .tag = switch (tag) {
                    .bit_and, .bool_and => .@"and",
                    .bit_or, .bool_or => .@"or",
                    else => unreachable,
                },
                .ops = .rrr,
                .data = .{
                    .r_type = .{
                        .rd = dst_reg,
                        .rs1 = lhs_reg,
                        .rs2 = rhs_reg,
                    },
                },
            });

            switch (tag) {
                .bool_and,
                .bool_or,
                => try func.truncateRegister(Type.bool, dst_reg),
                else => {},
            }
        },

        .div_trunc,
        => {
            if (!math.isPowerOfTwo(bit_size))
                return func.fail(
                    "TODO: genBinOp {s} non-pow 2, found {}",
                    .{ @tagName(tag), bit_size },
                );

            const mir_tag: Mir.Inst.Tag = switch (tag) {
                .div_trunc => switch (bit_size) {
                    8, 16, 32 => if (is_unsigned) .divuw else .divw,
                    64 => if (is_unsigned) .divu else .div,
                    else => unreachable,
                },
                else => unreachable,
            };

            _ = try func.addInst(.{
                .tag = mir_tag,
                .ops = .rrr,
                .data = .{
                    .r_type = .{
                        .rd = dst_reg,
                        .rs1 = lhs_reg,
                        .rs2 = rhs_reg,
                    },
                },
            });

            if (!is_unsigned) {
                // truncate when the instruction is larger than the bit size.
                switch (bit_size) {
                    8, 16 => try func.truncateRegister(lhs_ty, dst_reg),
                    32 => {}, // divw affects the first 32-bits
                    64 => {}, // div affects the entire register
                    else => unreachable,
                }
            }
        },

        .shr,
        .shr_exact,
        .shl,
        .shl_exact,
        => {
            if (!math.isPowerOfTwo(bit_size))
                return func.fail(
                    "TODO: genBinOp {s} non-pow 2, found {}",
                    .{ @tagName(tag), bit_size },
                );

            // it's important that the shift amount is exact
            try func.truncateRegister(rhs_ty, rhs_reg);

            const mir_tag: Mir.Inst.Tag = switch (tag) {
                .shl, .shl_exact => switch (bit_size) {
                    8, 16, 64 => .sll,
                    32 => .sllw,
                    else => unreachable,
                },
                .shr, .shr_exact => switch (bit_size) {
                    8, 16, 64 => .srl,
                    32 => .srlw,
                    else => unreachable,
                },
                else => unreachable,
            };

            _ = try func.addInst(.{
                .tag = mir_tag,
                .ops = .rrr,
                .data = .{ .r_type = .{
                    .rd = dst_reg,
                    .rs1 = lhs_reg,
                    .rs2 = rhs_reg,
                } },
            });

            switch (bit_size) {
                8, 16 => try func.truncateRegister(lhs_ty, dst_reg),
                32 => {},
                64 => {},
                else => unreachable,
            }
        },

        // TODO: move the isel logic out of lower and into here.
        .cmp_eq,
        .cmp_neq,
        .cmp_lt,
        .cmp_lte,
        .cmp_gt,
        .cmp_gte,
        => {
            _ = try func.addInst(.{
                .tag = .pseudo,
                .ops = .pseudo_compare,
                .data = .{
                    .compare = .{
                        .op = switch (tag) {
                            .cmp_eq => .eq,
                            .cmp_neq => .neq,
                            .cmp_lt => .lt,
                            .cmp_lte => .lte,
                            .cmp_gt => .gt,
                            .cmp_gte => .gte,
                            else => unreachable,
                        },
                        .rd = dst_reg,
                        .rs1 = lhs_reg,
                        .rs2 = rhs_reg,
                        .ty = lhs_ty,
                    },
                },
            });
        },

        // A branchless @min/@max sequence.
        //
        // Assume that a0 and a1 are the lhs and rhs respectively.
        // Also assume that a2 is the destination register.
        //
        // Algorithm:
        // slt s0, a0, a1
        // sub s0, zero, s0
        // xor a2, a0, a1
        // and s0, a2, s0
        // xor a2, a0, s0 # a0 is @min, a1 is @max
        //
        // "slt s0, a0, a1" will set s0 to 1 if a0 is less than a1, and 1 otherwise.
        //
        // "sub s0, zero, s0" will set all the bits of s0 to 1 if it was 1, otherwise it'll remain at 0.
        //
        // "xor a2, a0, a1" stores the bitwise XOR of a0 and a1 in a2. Effectively getting the difference between them.
        //
        // "and a0, a2, s0" here we mask the result of the XOR with the negated s0. If a0 < a1, s0 is -1, which
        // doesn't change the bits of a2. If a0 >= a1, s0 is 0, nullifying a2.
        //
        // "xor a2, a0, s0" the final XOR operation adjusts a2 to be the minimum value of a0 and a1. If a0 was less than
        // a1, s0 was -1, flipping all the bits in a2 and effectively restoring a0. If a0 was greater than or equal to a1,
        // s0 was 0, leaving a2 unchanged as a0.
        .min, .max => {
            const int_info = lhs_ty.intInfo(zcu);

            const mask_reg, const mask_lock = try func.allocReg(.int);
            defer func.register_manager.unlockReg(mask_lock);

            _ = try func.addInst(.{
                .tag = if (int_info.signedness == .unsigned) .sltu else .slt,
                .ops = .rrr,
                .data = .{ .r_type = .{
                    .rd = mask_reg,
                    .rs1 = lhs_reg,
                    .rs2 = rhs_reg,
                } },
            });

            _ = try func.addInst(.{
                .tag = .sub,
                .ops = .rrr,
                .data = .{ .r_type = .{
                    .rd = mask_reg,
                    .rs1 = .zero,
                    .rs2 = mask_reg,
                } },
            });

            _ = try func.addInst(.{
                .tag = .xor,
                .ops = .rrr,
                .data = .{ .r_type = .{
                    .rd = dst_reg,
                    .rs1 = lhs_reg,
                    .rs2 = rhs_reg,
                } },
            });

            _ = try func.addInst(.{
                .tag = .@"and",
                .ops = .rrr,
                .data = .{ .r_type = .{
                    .rd = mask_reg,
                    .rs1 = dst_reg,
                    .rs2 = mask_reg,
                } },
            });

            _ = try func.addInst(.{
                .tag = .xor,
                .ops = .rrr,
                .data = .{ .r_type = .{
                    .rd = dst_reg,
                    .rs1 = if (tag == .min) rhs_reg else lhs_reg,
                    .rs2 = mask_reg,
                } },
            });
        },
        else => return func.fail("TODO: genBinOp {}", .{tag}),
    }
}

fn airPtrArithmetic(func: *Func, inst: Air.Inst.Index, tag: Air.Inst.Tag) !void {
    const ty_pl = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const bin_op = func.air.extraData(Air.Bin, ty_pl.payload).data;
    const dst_mcv = try func.binOp(inst, tag, bin_op.lhs, bin_op.rhs);
    return func.finishAir(inst, dst_mcv, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airAddWithOverflow(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const ty_pl = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const extra = func.air.extraData(Air.Bin, ty_pl.payload).data;

    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else result: {
        const lhs_ty = func.typeOf(extra.lhs);

        const int_info = lhs_ty.intInfo(zcu);

        const tuple_ty = func.typeOfIndex(inst);
        const result_mcv = try func.allocRegOrMem(tuple_ty, inst, false);
        const offset = result_mcv.load_frame;

        if (int_info.bits >= 8 and math.isPowerOfTwo(int_info.bits)) {
            const add_result = try func.binOp(null, .add, extra.lhs, extra.rhs);
            const add_result_reg = try func.copyToTmpRegister(lhs_ty, add_result);
            const add_result_reg_lock = func.register_manager.lockRegAssumeUnused(add_result_reg);
            defer func.register_manager.unlockReg(add_result_reg_lock);

            const shift_amount: u6 = @intCast(Type.usize.bitSize(zcu) - int_info.bits);

            const shift_reg, const shift_lock = try func.allocReg(.int);
            defer func.register_manager.unlockReg(shift_lock);

            _ = try func.addInst(.{
                .tag = .slli,
                .ops = .rri,
                .data = .{
                    .i_type = .{
                        .rd = shift_reg,
                        .rs1 = add_result_reg,
                        .imm12 = Immediate.u(shift_amount),
                    },
                },
            });

            _ = try func.addInst(.{
                .tag = if (int_info.signedness == .unsigned) .srli else .srai,
                .ops = .rri,
                .data = .{
                    .i_type = .{
                        .rd = shift_reg,
                        .rs1 = shift_reg,
                        .imm12 = Immediate.u(shift_amount),
                    },
                },
            });

            try func.genSetMem(
                .{ .frame = offset.index },
                offset.off + @as(i32, @intCast(tuple_ty.structFieldOffset(0, zcu))),
                lhs_ty,
                add_result,
            );

            const overflow_reg, const overflow_lock = try func.allocReg(.int);
            defer func.register_manager.unlockReg(overflow_lock);

            try func.genBinOp(
                .cmp_neq,
                .{ .register = shift_reg },
                lhs_ty,
                .{ .register = add_result_reg },
                lhs_ty,
                overflow_reg,
            );

            try func.genSetMem(
                .{ .frame = offset.index },
                offset.off + @as(i32, @intCast(tuple_ty.structFieldOffset(1, zcu))),
                Type.u1,
                .{ .register = overflow_reg },
            );

            break :result result_mcv;
        } else {
            return func.fail("TODO: less than 8 bit or non-pow 2 addition", .{});
        }
    };

    return func.finishAir(inst, result, .{ extra.lhs, extra.rhs, .none });
}

fn airSubWithOverflow(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const ty_pl = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const extra = func.air.extraData(Air.Bin, ty_pl.payload).data;

    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else result: {
        const lhs = try func.resolveInst(extra.lhs);
        const rhs = try func.resolveInst(extra.rhs);
        const lhs_ty = func.typeOf(extra.lhs);
        const rhs_ty = func.typeOf(extra.rhs);

        const int_info = lhs_ty.intInfo(zcu);

        if (!math.isPowerOfTwo(int_info.bits) or int_info.bits < 8) {
            return func.fail("TODO: airSubWithOverflow non-power of 2 and less than 8 bits", .{});
        }

        if (int_info.bits > 64) {
            return func.fail("TODO: airSubWithOverflow > 64 bits", .{});
        }

        const tuple_ty = func.typeOfIndex(inst);
        const result_mcv = try func.allocRegOrMem(tuple_ty, inst, false);
        const offset = result_mcv.load_frame;

        const dest_mcv = try func.binOp(null, .sub, extra.lhs, extra.rhs);
        assert(dest_mcv == .register);
        const dest_reg = dest_mcv.register;

        try func.genSetMem(
            .{ .frame = offset.index },
            offset.off + @as(i32, @intCast(tuple_ty.structFieldOffset(0, zcu))),
            lhs_ty,
            .{ .register = dest_reg },
        );

        const lhs_reg, const lhs_lock = try func.promoteReg(lhs_ty, lhs);
        defer if (lhs_lock) |lock| func.register_manager.unlockReg(lock);

        const rhs_reg, const rhs_lock = try func.promoteReg(rhs_ty, rhs);
        defer if (rhs_lock) |lock| func.register_manager.unlockReg(lock);

        const overflow_reg = try func.copyToTmpRegister(Type.usize, .{ .immediate = 0 });

        const overflow_lock = func.register_manager.lockRegAssumeUnused(overflow_reg);
        defer func.register_manager.unlockReg(overflow_lock);

        switch (int_info.signedness) {
            .unsigned => {
                _ = try func.addInst(.{
                    .tag = .sltu,
                    .ops = .rrr,
                    .data = .{ .r_type = .{
                        .rd = overflow_reg,
                        .rs1 = lhs_reg,
                        .rs2 = rhs_reg,
                    } },
                });

                try func.genSetMem(
                    .{ .frame = offset.index },
                    offset.off + @as(i32, @intCast(tuple_ty.structFieldOffset(1, zcu))),
                    Type.u1,
                    .{ .register = overflow_reg },
                );

                break :result result_mcv;
            },
            .signed => {
                switch (int_info.bits) {
                    64 => {
                        _ = try func.addInst(.{
                            .tag = .slt,
                            .ops = .rrr,
                            .data = .{ .r_type = .{
                                .rd = overflow_reg,
                                .rs1 = overflow_reg,
                                .rs2 = rhs_reg,
                            } },
                        });

                        _ = try func.addInst(.{
                            .tag = .slt,
                            .ops = .rrr,
                            .data = .{ .r_type = .{
                                .rd = rhs_reg,
                                .rs1 = rhs_reg,
                                .rs2 = lhs_reg,
                            } },
                        });

                        _ = try func.addInst(.{
                            .tag = .xor,
                            .ops = .rrr,
                            .data = .{ .r_type = .{
                                .rd = lhs_reg,
                                .rs1 = overflow_reg,
                                .rs2 = rhs_reg,
                            } },
                        });

                        try func.genBinOp(
                            .cmp_neq,
                            .{ .register = overflow_reg },
                            Type.usize,
                            .{ .register = rhs_reg },
                            Type.usize,
                            overflow_reg,
                        );

                        try func.genSetMem(
                            .{ .frame = offset.index },
                            offset.off + @as(i32, @intCast(tuple_ty.structFieldOffset(1, zcu))),
                            Type.u1,
                            .{ .register = overflow_reg },
                        );

                        break :result result_mcv;
                    },
                    else => |int_bits| return func.fail("TODO: airSubWithOverflow signed {}", .{int_bits}),
                }
            },
        }
    };

    return func.finishAir(inst, result, .{ extra.lhs, extra.rhs, .none });
}

fn airMulWithOverflow(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const ty_pl = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const extra = func.air.extraData(Air.Bin, ty_pl.payload).data;

    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else result: {
        const lhs = try func.resolveInst(extra.lhs);
        const rhs = try func.resolveInst(extra.rhs);
        const lhs_ty = func.typeOf(extra.lhs);
        const rhs_ty = func.typeOf(extra.rhs);

        const tuple_ty = func.typeOfIndex(inst);

        // genSetReg needs to support register_offset src_mcv for this to be true.
        const result_mcv = try func.allocRegOrMem(tuple_ty, inst, false);

        const result_off: i32 = @intCast(tuple_ty.structFieldOffset(0, zcu));
        const overflow_off: i32 = @intCast(tuple_ty.structFieldOffset(1, zcu));

        const dest_reg, const dest_lock = try func.allocReg(.int);
        defer func.register_manager.unlockReg(dest_lock);

        try func.genBinOp(
            .mul,
            lhs,
            lhs_ty,
            rhs,
            rhs_ty,
            dest_reg,
        );

        try func.genCopy(
            lhs_ty,
            result_mcv.offset(result_off),
            .{ .register = dest_reg },
        );

        switch (lhs_ty.zigTypeTag(zcu)) {
            else => |x| return func.fail("TODO: airMulWithOverflow {s}", .{@tagName(x)}),
            .Int => {
                assert(lhs_ty.eql(rhs_ty, zcu));
                const int_info = lhs_ty.intInfo(zcu);
                switch (int_info.bits) {
                    1...32 => {
                        if (int_info.bits >= 8 and math.isPowerOfTwo(int_info.bits)) {
                            if (int_info.signedness == .unsigned) {
                                switch (int_info.bits) {
                                    1...8 => {
                                        const max_val = std.math.pow(u16, 2, int_info.bits) - 1;

                                        const add_reg, const add_lock = try func.promoteReg(lhs_ty, lhs);
                                        defer if (add_lock) |lock| func.register_manager.unlockReg(lock);

                                        const overflow_reg, const overflow_lock = try func.allocReg(.int);
                                        defer func.register_manager.unlockReg(overflow_lock);

                                        _ = try func.addInst(.{
                                            .tag = .andi,
                                            .ops = .rri,
                                            .data = .{ .i_type = .{
                                                .rd = overflow_reg,
                                                .rs1 = add_reg,
                                                .imm12 = Immediate.s(max_val),
                                            } },
                                        });

                                        try func.genBinOp(
                                            .cmp_neq,
                                            .{ .register = overflow_reg },
                                            lhs_ty,
                                            .{ .register = add_reg },
                                            lhs_ty,
                                            overflow_reg,
                                        );

                                        try func.genCopy(
                                            lhs_ty,
                                            result_mcv.offset(overflow_off),
                                            .{ .register = overflow_reg },
                                        );

                                        break :result result_mcv;
                                    },

                                    else => return func.fail("TODO: airMulWithOverflow check for size {d}", .{int_info.bits}),
                                }
                            } else {
                                return func.fail("TODO: airMulWithOverflow calculate carry for signed addition", .{});
                            }
                        } else {
                            return func.fail("TODO: airMulWithOverflow with < 8 bits or non-pow of 2", .{});
                        }
                    },
                    else => return func.fail("TODO: airMulWithOverflow larger than 32-bit mul", .{}),
                }
            },
        }
    };

    return func.finishAir(inst, result, .{ extra.lhs, extra.rhs, .none });
}

fn airShlWithOverflow(func: *Func, inst: Air.Inst.Index) !void {
    const bin_op = func.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airShlWithOverflow", .{});
    return func.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airAddSat(func: *Func, inst: Air.Inst.Index) !void {
    const bin_op = func.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airAddSat", .{});
    return func.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airSubSat(func: *Func, inst: Air.Inst.Index) !void {
    const bin_op = func.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airSubSat", .{});
    return func.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airMulSat(func: *Func, inst: Air.Inst.Index) !void {
    const bin_op = func.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airMulSat", .{});
    return func.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airShlSat(func: *Func, inst: Air.Inst.Index) !void {
    const bin_op = func.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airShlSat", .{});
    return func.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airOptionalPayload(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = result: {
        const pl_ty = func.typeOfIndex(inst);
        if (!pl_ty.hasRuntimeBitsIgnoreComptime(zcu)) break :result .none;

        const opt_mcv = try func.resolveInst(ty_op.operand);
        if (func.reuseOperand(inst, ty_op.operand, 0, opt_mcv)) {
            switch (opt_mcv) {
                .register => |pl_reg| try func.truncateRegister(pl_ty, pl_reg),
                else => {},
            }
            break :result opt_mcv;
        }

        const pl_mcv = try func.allocRegOrMem(pl_ty, inst, true);
        try func.genCopy(pl_ty, pl_mcv, opt_mcv);
        break :result pl_mcv;
    };
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airOptionalPayloadPtr(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement .optional_payload_ptr for {}", .{func.target.cpu.arch});
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airOptionalPayloadPtrSet(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement .optional_payload_ptr_set for {}", .{func.target.cpu.arch});
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airUnwrapErrErr(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const zcu = func.bin_file.comp.module.?;
    const err_union_ty = func.typeOf(ty_op.operand);
    const err_ty = err_union_ty.errorUnionSet(zcu);
    const payload_ty = err_union_ty.errorUnionPayload(zcu);
    const operand = try func.resolveInst(ty_op.operand);

    const result: MCValue = result: {
        if (err_ty.errorSetIsEmpty(zcu)) {
            break :result .{ .immediate = 0 };
        }

        if (!payload_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
            break :result operand;
        }

        const err_off: u32 = @intCast(errUnionErrorOffset(payload_ty, zcu));

        switch (operand) {
            .register => |reg| {
                const eu_lock = func.register_manager.lockReg(reg);
                defer if (eu_lock) |lock| func.register_manager.unlockReg(lock);

                const result = try func.copyToNewRegister(inst, operand);
                if (err_off > 0) {
                    try func.genBinOp(
                        .shr,
                        result,
                        err_union_ty,
                        .{ .immediate = @as(u6, @intCast(err_off * 8)) },
                        Type.u8,
                        result.register,
                    );
                }
                break :result result;
            },
            .load_frame => |frame_addr| break :result .{ .load_frame = .{
                .index = frame_addr.index,
                .off = frame_addr.off + @as(i32, @intCast(err_off)),
            } },
            else => return func.fail("TODO implement unwrap_err_err for {}", .{operand}),
        }
    };

    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airUnwrapErrPayload(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const operand_ty = func.typeOf(ty_op.operand);
    const operand = try func.resolveInst(ty_op.operand);
    const result = try func.genUnwrapErrUnionPayloadMir(operand_ty, operand);
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn genUnwrapErrUnionPayloadMir(
    func: *Func,
    err_union_ty: Type,
    err_union: MCValue,
) !MCValue {
    const zcu = func.bin_file.comp.module.?;
    const payload_ty = err_union_ty.errorUnionPayload(zcu);

    const result: MCValue = result: {
        if (!payload_ty.hasRuntimeBitsIgnoreComptime(zcu)) break :result .none;

        const payload_off: u31 = @intCast(errUnionPayloadOffset(payload_ty, zcu));
        switch (err_union) {
            .load_frame => |frame_addr| break :result .{ .load_frame = .{
                .index = frame_addr.index,
                .off = frame_addr.off + payload_off,
            } },
            .register => |reg| {
                const eu_lock = func.register_manager.lockReg(reg);
                defer if (eu_lock) |lock| func.register_manager.unlockReg(lock);

                const result_reg = try func.copyToTmpRegister(err_union_ty, err_union);
                if (payload_off > 0) {
                    try func.genBinOp(
                        .shr,
                        .{ .register = result_reg },
                        err_union_ty,
                        .{ .immediate = @as(u6, @intCast(payload_off * 8)) },
                        Type.u8,
                        result_reg,
                    );
                }
                break :result .{ .register = result_reg };
            },
            else => return func.fail("TODO implement genUnwrapErrUnionPayloadMir for {}", .{err_union}),
        }
    };

    return result;
}

// *(E!T) -> E
fn airUnwrapErrErrPtr(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement unwrap error union error ptr for {}", .{func.target.cpu.arch});
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

// *(E!T) -> *T
fn airUnwrapErrPayloadPtr(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement unwrap error union payload ptr for {}", .{func.target.cpu.arch});
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airErrUnionPayloadPtrSet(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement .errunion_payload_ptr_set for {}", .{func.target.cpu.arch});
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airErrReturnTrace(func: *Func, inst: Air.Inst.Index) !void {
    const result: MCValue = if (func.liveness.isUnused(inst))
        .unreach
    else
        return func.fail("TODO implement airErrReturnTrace for {}", .{func.target.cpu.arch});
    return func.finishAir(inst, result, .{ .none, .none, .none });
}

fn airSetErrReturnTrace(func: *Func, inst: Air.Inst.Index) !void {
    _ = inst;
    return func.fail("TODO implement airSetErrReturnTrace for {}", .{func.target.cpu.arch});
}

fn airSaveErrReturnTraceIndex(func: *Func, inst: Air.Inst.Index) !void {
    _ = inst;
    return func.fail("TODO implement airSaveErrReturnTraceIndex for {}", .{func.target.cpu.arch});
}

fn airWrapOptional(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = result: {
        const pl_ty = func.typeOf(ty_op.operand);
        if (!pl_ty.hasRuntimeBits(zcu)) break :result .{ .immediate = 1 };

        const opt_ty = func.typeOfIndex(inst);
        const pl_mcv = try func.resolveInst(ty_op.operand);
        const same_repr = opt_ty.optionalReprIsPayload(zcu);
        if (same_repr and func.reuseOperand(inst, ty_op.operand, 0, pl_mcv)) break :result pl_mcv;

        const pl_lock: ?RegisterLock = switch (pl_mcv) {
            .register => |reg| func.register_manager.lockRegAssumeUnused(reg),
            else => null,
        };
        defer if (pl_lock) |lock| func.register_manager.unlockReg(lock);

        const opt_mcv = try func.allocRegOrMem(opt_ty, inst, true);
        try func.genCopy(pl_ty, opt_mcv, pl_mcv);

        if (!same_repr) {
            const pl_abi_size: i32 = @intCast(pl_ty.abiSize(zcu));
            switch (opt_mcv) {
                .load_frame => |frame_addr| try func.genSetMem(
                    .{ .frame = frame_addr.index },
                    frame_addr.off + pl_abi_size,
                    Type.u8,
                    .{ .immediate = 1 },
                ),
                .register => return func.fail("TODO: airWrapOption opt_mcv register", .{}),
                else => unreachable,
            }
        }
        break :result opt_mcv;
    };
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

/// T to E!T
fn airWrapErrUnionPayload(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;

    const eu_ty = ty_op.ty.toType();
    const pl_ty = eu_ty.errorUnionPayload(zcu);
    const err_ty = eu_ty.errorUnionSet(zcu);
    const operand = try func.resolveInst(ty_op.operand);

    const result: MCValue = result: {
        if (!pl_ty.hasRuntimeBitsIgnoreComptime(zcu)) break :result .{ .immediate = 0 };

        const frame_index = try func.allocFrameIndex(FrameAlloc.initSpill(eu_ty, zcu));
        const pl_off: i32 = @intCast(errUnionPayloadOffset(pl_ty, zcu));
        const err_off: i32 = @intCast(errUnionErrorOffset(pl_ty, zcu));
        try func.genSetMem(.{ .frame = frame_index }, pl_off, pl_ty, operand);
        try func.genSetMem(.{ .frame = frame_index }, err_off, err_ty, .{ .immediate = 0 });
        break :result .{ .load_frame = .{ .index = frame_index } };
    };

    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

/// E to E!T
fn airWrapErrUnionErr(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;

    const eu_ty = ty_op.ty.toType();
    const pl_ty = eu_ty.errorUnionPayload(zcu);
    const err_ty = eu_ty.errorUnionSet(zcu);

    const result: MCValue = result: {
        if (!pl_ty.hasRuntimeBitsIgnoreComptime(zcu)) break :result try func.resolveInst(ty_op.operand);

        const frame_index = try func.allocFrameIndex(FrameAlloc.initSpill(eu_ty, zcu));
        const pl_off: i32 = @intCast(errUnionPayloadOffset(pl_ty, zcu));
        const err_off: i32 = @intCast(errUnionErrorOffset(pl_ty, zcu));
        try func.genSetMem(.{ .frame = frame_index }, pl_off, pl_ty, .undef);
        const operand = try func.resolveInst(ty_op.operand);
        try func.genSetMem(.{ .frame = frame_index }, err_off, err_ty, operand);
        break :result .{ .load_frame = .{ .index = frame_index } };
    };
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airTry(func: *Func, inst: Air.Inst.Index) !void {
    const pl_op = func.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
    const extra = func.air.extraData(Air.Try, pl_op.payload);
    const body: []const Air.Inst.Index = @ptrCast(func.air.extra[extra.end..][0..extra.data.body_len]);
    const operand_ty = func.typeOf(pl_op.operand);
    const result = try func.genTry(inst, pl_op.operand, body, operand_ty, false);
    return func.finishAir(inst, result, .{ .none, .none, .none });
}

fn genTry(
    func: *Func,
    inst: Air.Inst.Index,
    operand: Air.Inst.Ref,
    body: []const Air.Inst.Index,
    operand_ty: Type,
    operand_is_ptr: bool,
) !MCValue {
    _ = operand_is_ptr;

    const liveness_cond_br = func.liveness.getCondBr(inst);

    const operand_mcv = try func.resolveInst(operand);
    const is_err_mcv = try func.isErr(null, operand_ty, operand_mcv);

    // A branch to the false section. Uses beq. 1 is the default "true" state.
    const reloc = try func.condBr(Type.anyerror, is_err_mcv);

    if (func.liveness.operandDies(inst, 0)) {
        if (operand.toIndex()) |operand_inst| try func.processDeath(operand_inst);
    }

    func.scope_generation += 1;
    const state = try func.saveState();

    for (liveness_cond_br.else_deaths) |death| try func.processDeath(death);
    try func.genBody(body);
    try func.restoreState(state, &.{}, .{
        .emit_instructions = false,
        .update_tracking = true,
        .resurrect = true,
        .close_scope = true,
    });

    func.performReloc(reloc);

    for (liveness_cond_br.then_deaths) |death| try func.processDeath(death);

    const result = if (func.liveness.isUnused(inst))
        .unreach
    else
        try func.genUnwrapErrUnionPayloadMir(operand_ty, operand_mcv);

    return result;
}

fn airSlicePtr(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result = result: {
        const src_mcv = try func.resolveInst(ty_op.operand);
        if (func.reuseOperand(inst, ty_op.operand, 0, src_mcv)) break :result src_mcv;

        const dst_mcv = try func.allocRegOrMem(func.typeOfIndex(inst), inst, true);
        const dst_ty = func.typeOfIndex(inst);
        try func.genCopy(dst_ty, dst_mcv, src_mcv);
        break :result dst_mcv;
    };
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airSliceLen(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else result: {
        const src_mcv = try func.resolveInst(ty_op.operand);
        const ty = func.typeOfIndex(inst);

        switch (src_mcv) {
            .load_frame => |frame_addr| {
                const len_mcv: MCValue = .{ .load_frame = .{
                    .index = frame_addr.index,
                    .off = frame_addr.off + 8,
                } };
                if (func.reuseOperand(inst, ty_op.operand, 0, src_mcv)) break :result len_mcv;

                const dst_mcv = try func.allocRegOrMem(ty, inst, true);
                try func.genCopy(Type.usize, dst_mcv, len_mcv);
                break :result dst_mcv;
            },
            .register_pair => |pair| {
                const len_mcv: MCValue = .{ .register = pair[1] };

                if (func.reuseOperand(inst, ty_op.operand, 0, src_mcv)) break :result len_mcv;

                const dst_mcv = try func.allocRegOrMem(ty, inst, true);
                try func.genCopy(Type.usize, dst_mcv, len_mcv);
                break :result dst_mcv;
            },
            else => return func.fail("TODO airSliceLen for {}", .{src_mcv}),
        }
    };
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airPtrSliceLenPtr(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement ptr_slice_len_ptr for {}", .{func.target.cpu.arch});
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airPtrSlicePtrPtr(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement ptr_slice_ptr_ptr for {}", .{func.target.cpu.arch});
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airSliceElemVal(func: *Func, inst: Air.Inst.Index) !void {
    const mod = func.bin_file.comp.module.?;
    const bin_op = func.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

    const result: MCValue = result: {
        const elem_ty = func.typeOfIndex(inst);
        if (!elem_ty.hasRuntimeBitsIgnoreComptime(mod)) break :result .none;

        const slice_ty = func.typeOf(bin_op.lhs);
        const slice_ptr_field_type = slice_ty.slicePtrFieldType(mod);
        const elem_ptr = try func.genSliceElemPtr(bin_op.lhs, bin_op.rhs);
        const dst_mcv = try func.allocRegOrMem(elem_ty, inst, false);
        try func.load(dst_mcv, elem_ptr, slice_ptr_field_type);
        break :result dst_mcv;
    };
    return func.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airSliceElemPtr(func: *Func, inst: Air.Inst.Index) !void {
    const ty_pl = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const extra = func.air.extraData(Air.Bin, ty_pl.payload).data;
    const dst_mcv = try func.genSliceElemPtr(extra.lhs, extra.rhs);
    return func.finishAir(inst, dst_mcv, .{ extra.lhs, extra.rhs, .none });
}

fn genSliceElemPtr(func: *Func, lhs: Air.Inst.Ref, rhs: Air.Inst.Ref) !MCValue {
    const zcu = func.bin_file.comp.module.?;
    const slice_ty = func.typeOf(lhs);
    const slice_mcv = try func.resolveInst(lhs);
    const slice_mcv_lock: ?RegisterLock = switch (slice_mcv) {
        .register => |reg| func.register_manager.lockRegAssumeUnused(reg),
        else => null,
    };
    defer if (slice_mcv_lock) |lock| func.register_manager.unlockReg(lock);

    const elem_ty = slice_ty.childType(zcu);
    const elem_size = elem_ty.abiSize(zcu);

    const index_ty = func.typeOf(rhs);
    const index_mcv = try func.resolveInst(rhs);
    const index_mcv_lock: ?RegisterLock = switch (index_mcv) {
        .register => |reg| func.register_manager.lockRegAssumeUnused(reg),
        else => null,
    };
    defer if (index_mcv_lock) |lock| func.register_manager.unlockReg(lock);

    const offset_reg = try func.elemOffset(index_ty, index_mcv, elem_size);
    const offset_reg_lock = func.register_manager.lockRegAssumeUnused(offset_reg);
    defer func.register_manager.unlockReg(offset_reg_lock);

    const addr_reg, const addr_lock = try func.allocReg(.int);
    defer func.register_manager.unlockReg(addr_lock);
    try func.genSetReg(Type.usize, addr_reg, slice_mcv);

    _ = try func.addInst(.{
        .tag = .add,
        .ops = .rrr,
        .data = .{ .r_type = .{
            .rd = addr_reg,
            .rs1 = addr_reg,
            .rs2 = offset_reg,
        } },
    });

    return .{ .register = addr_reg };
}

fn airArrayElemVal(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const bin_op = func.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else result: {
        const result_ty = func.typeOfIndex(inst);

        const array_ty = func.typeOf(bin_op.lhs);
        const array_mcv = try func.resolveInst(bin_op.lhs);

        const index_mcv = try func.resolveInst(bin_op.rhs);
        const index_ty = func.typeOf(bin_op.rhs);

        const elem_ty = array_ty.childType(zcu);
        const elem_abi_size = elem_ty.abiSize(zcu);

        const addr_reg, const addr_reg_lock = try func.allocReg(.int);
        defer func.register_manager.unlockReg(addr_reg_lock);

        switch (array_mcv) {
            .register => {
                const frame_index = try func.allocFrameIndex(FrameAlloc.initType(array_ty, zcu));
                try func.genSetMem(.{ .frame = frame_index }, 0, array_ty, array_mcv);
                try func.genSetReg(Type.usize, addr_reg, .{ .lea_frame = .{ .index = frame_index } });
            },
            .load_frame => |frame_addr| {
                try func.genSetReg(Type.usize, addr_reg, .{ .lea_frame = frame_addr });
            },
            else => try func.genSetReg(Type.usize, addr_reg, array_mcv.address()),
        }

        const offset_reg = try func.elemOffset(index_ty, index_mcv, elem_abi_size);
        const offset_lock = func.register_manager.lockRegAssumeUnused(offset_reg);
        defer func.register_manager.unlockReg(offset_lock);

        const dst_mcv = try func.allocRegOrMem(result_ty, inst, false);
        _ = try func.addInst(.{
            .tag = .add,
            .ops = .rrr,
            .data = .{ .r_type = .{
                .rd = addr_reg,
                .rs1 = offset_reg,
                .rs2 = addr_reg,
            } },
        });
        try func.genCopy(elem_ty, dst_mcv, .{ .indirect = .{ .reg = addr_reg } });
        break :result dst_mcv;
    };
    return func.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airPtrElemVal(func: *Func, inst: Air.Inst.Index) !void {
    const is_volatile = false; // TODO
    const bin_op = func.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const result: MCValue = if (!is_volatile and func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement ptr_elem_val for {}", .{func.target.cpu.arch});
    return func.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airPtrElemPtr(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const ty_pl = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const extra = func.air.extraData(Air.Bin, ty_pl.payload).data;

    const result = result: {
        const elem_ptr_ty = func.typeOfIndex(inst);
        const base_ptr_ty = func.typeOf(extra.lhs);

        const base_ptr_mcv = try func.resolveInst(extra.lhs);
        const base_ptr_lock: ?RegisterLock = switch (base_ptr_mcv) {
            .register => |reg| func.register_manager.lockRegAssumeUnused(reg),
            else => null,
        };
        defer if (base_ptr_lock) |lock| func.register_manager.unlockReg(lock);

        if (elem_ptr_ty.ptrInfo(zcu).flags.vector_index != .none) {
            break :result if (func.reuseOperand(inst, extra.lhs, 0, base_ptr_mcv))
                base_ptr_mcv
            else
                try func.copyToNewRegister(inst, base_ptr_mcv);
        }

        const elem_ty = base_ptr_ty.elemType2(zcu);
        const elem_abi_size = elem_ty.abiSize(zcu);
        const index_ty = func.typeOf(extra.rhs);
        const index_mcv = try func.resolveInst(extra.rhs);
        const index_lock: ?RegisterLock = switch (index_mcv) {
            .register => |reg| func.register_manager.lockRegAssumeUnused(reg),
            else => null,
        };
        defer if (index_lock) |lock| func.register_manager.unlockReg(lock);

        const offset_reg = try func.elemOffset(index_ty, index_mcv, elem_abi_size);
        const offset_reg_lock = func.register_manager.lockRegAssumeUnused(offset_reg);
        defer func.register_manager.unlockReg(offset_reg_lock);

        const result_reg, const result_lock = try func.allocReg(.int);
        defer func.register_manager.unlockReg(result_lock);

        try func.genBinOp(
            .ptr_add,
            base_ptr_mcv,
            base_ptr_ty,
            .{ .register = offset_reg },
            Type.usize,
            result_reg,
        );

        break :result MCValue{ .register = result_reg };
    };
    return func.finishAir(inst, result, .{ extra.lhs, extra.rhs, .none });
}

fn airSetUnionTag(func: *Func, inst: Air.Inst.Index) !void {
    const bin_op = func.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    _ = bin_op;
    return func.fail("TODO implement airSetUnionTag for {}", .{func.target.cpu.arch});
    // return func.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airGetUnionTag(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airGetUnionTag for {}", .{func.target.cpu.arch});
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airClz(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airClz for {}", .{func.target.cpu.arch});
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airCtz(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    _ = ty_op;
    return func.fail("TODO: finish ctz", .{});
}

fn airPopcount(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airPopcount for {}", .{func.target.cpu.arch});
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airAbs(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else result: {
        const ty = func.typeOf(ty_op.operand);
        const scalar_ty = ty.scalarType(zcu);
        const operand = try func.resolveInst(ty_op.operand);

        switch (scalar_ty.zigTypeTag(zcu)) {
            .Int => if (ty.zigTypeTag(zcu) == .Vector) {
                return func.fail("TODO implement airAbs for {}", .{ty.fmt(zcu)});
            } else {
                const return_mcv = try func.copyToNewRegister(inst, operand);
                const operand_reg = return_mcv.register;

                const temp_reg, const temp_lock = try func.allocReg(.int);
                defer func.register_manager.unlockReg(temp_lock);

                _ = try func.addInst(.{
                    .tag = .srai,
                    .ops = .rri,
                    .data = .{ .i_type = .{
                        .rd = temp_reg,
                        .rs1 = operand_reg,
                        .imm12 = Immediate.u(63),
                    } },
                });

                _ = try func.addInst(.{
                    .tag = .xor,
                    .ops = .rrr,
                    .data = .{ .r_type = .{
                        .rd = operand_reg,
                        .rs1 = operand_reg,
                        .rs2 = temp_reg,
                    } },
                });

                _ = try func.addInst(.{
                    .tag = .sub,
                    .ops = .rrr,
                    .data = .{ .r_type = .{
                        .rd = operand_reg,
                        .rs1 = operand_reg,
                        .rs2 = temp_reg,
                    } },
                });

                break :result return_mcv;
            },
            .Float => {
                const float_bits = scalar_ty.floatBits(zcu.getTarget());
                switch (float_bits) {
                    16 => return func.fail("TODO: airAbs 16-bit float", .{}),
                    32 => {},
                    64 => {},
                    80 => return func.fail("TODO: airAbs 80-bit float", .{}),
                    128 => return func.fail("TODO: airAbs 128-bit float", .{}),
                    else => unreachable,
                }

                const return_mcv = try func.copyToNewRegister(inst, operand);
                const operand_reg = return_mcv.register;

                assert(operand_reg.class() == .float);

                _ = try func.addInst(.{
                    .tag = .pseudo,
                    .ops = .pseudo_fabs,
                    .data = .{
                        .fabs = .{
                            .rd = operand_reg,
                            .rs = operand_reg,
                            .bits = float_bits,
                        },
                    },
                });

                break :result return_mcv;
            },
            else => return func.fail("TODO: implement airAbs {}", .{scalar_ty.fmt(zcu)}),
        }

        break :result .unreach;
    };
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airByteSwap(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else result: {
        const zcu = func.bin_file.comp.module.?;
        const ty = func.typeOf(ty_op.operand);
        const operand = try func.resolveInst(ty_op.operand);

        const int_bits = ty.intInfo(zcu).bits;

        // bytes are no-op
        if (int_bits == 8 and func.reuseOperand(inst, ty_op.operand, 0, operand)) {
            return func.finishAir(inst, operand, .{ ty_op.operand, .none, .none });
        }

        const dest_mcv = try func.copyToNewRegister(inst, operand);
        const dest_reg = dest_mcv.register;

        switch (int_bits) {
            16 => {
                const temp_reg, const temp_lock = try func.allocReg(.int);
                defer func.register_manager.unlockReg(temp_lock);

                _ = try func.addInst(.{
                    .tag = .srli,
                    .ops = .rri,
                    .data = .{ .i_type = .{
                        .imm12 = Immediate.s(8),
                        .rd = temp_reg,
                        .rs1 = dest_reg,
                    } },
                });

                _ = try func.addInst(.{
                    .tag = .slli,
                    .ops = .rri,
                    .data = .{ .i_type = .{
                        .imm12 = Immediate.s(8),
                        .rd = dest_reg,
                        .rs1 = dest_reg,
                    } },
                });
                _ = try func.addInst(.{
                    .tag = .@"or",
                    .ops = .rri,
                    .data = .{ .r_type = .{
                        .rd = dest_reg,
                        .rs1 = dest_reg,
                        .rs2 = temp_reg,
                    } },
                });
            },
            else => return func.fail("TODO: {d} bits for airByteSwap", .{int_bits}),
        }

        break :result dest_mcv;
    };
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airBitReverse(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airBitReverse for {}", .{func.target.cpu.arch});
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airUnaryMath(func: *Func, inst: Air.Inst.Index) !void {
    const tag = func.air.instructions.items(.tag)[@intFromEnum(inst)];
    const un_op = func.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const result: MCValue = if (func.liveness.isUnused(inst))
        .unreach
    else
        return func.fail("TODO implementairUnaryMath {s} for {}", .{ @tagName(tag), func.target.cpu.arch });
    return func.finishAir(inst, result, .{ un_op, .none, .none });
}

fn reuseOperand(
    func: *Func,
    inst: Air.Inst.Index,
    operand: Air.Inst.Ref,
    op_index: Liveness.OperandInt,
    mcv: MCValue,
) bool {
    return func.reuseOperandAdvanced(inst, operand, op_index, mcv, inst);
}

fn reuseOperandAdvanced(
    func: *Func,
    inst: Air.Inst.Index,
    operand: Air.Inst.Ref,
    op_index: Liveness.OperandInt,
    mcv: MCValue,
    maybe_tracked_inst: ?Air.Inst.Index,
) bool {
    if (!func.liveness.operandDies(inst, op_index))
        return false;

    switch (mcv) {
        .register,
        .register_pair,
        => for (mcv.getRegs()) |reg| {
            // If it's in the registers table, need to associate the register(s) with the
            // new instruction.
            if (maybe_tracked_inst) |tracked_inst| {
                if (!func.register_manager.isRegFree(reg)) {
                    if (RegisterManager.indexOfRegIntoTracked(reg)) |index| {
                        func.register_manager.registers[index] = tracked_inst;
                    }
                }
            } else func.register_manager.freeReg(reg);
        },
        .load_frame => |frame_addr| if (frame_addr.index.isNamed()) return false,
        else => return false,
    }

    // Prevent the operand deaths processing code from deallocating it.
    func.liveness.clearOperandDeath(inst, op_index);
    const op_inst = operand.toIndex().?;
    func.getResolvedInstValue(op_inst).reuse(func, maybe_tracked_inst, op_inst);

    return true;
}

fn airLoad(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const elem_ty = func.typeOfIndex(inst);

    const result: MCValue = result: {
        if (!elem_ty.hasRuntimeBits(zcu))
            break :result .none;

        const ptr = try func.resolveInst(ty_op.operand);
        const is_volatile = func.typeOf(ty_op.operand).isVolatilePtr(zcu);
        if (func.liveness.isUnused(inst) and !is_volatile)
            break :result .unreach;

        const elem_size = elem_ty.abiSize(zcu);

        const dst_mcv: MCValue = blk: {
            // Pointer is 8 bytes, and if the element is more than that, we cannot reuse it.
            if (elem_size <= 8 and func.reuseOperand(inst, ty_op.operand, 0, ptr)) {
                // The MCValue that holds the pointer can be re-used as the value.
                break :blk ptr;
            } else {
                break :blk try func.allocRegOrMem(elem_ty, inst, true);
            }
        };

        try func.load(dst_mcv, ptr, func.typeOf(ty_op.operand));
        break :result dst_mcv;
    };
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn load(func: *Func, dst_mcv: MCValue, ptr_mcv: MCValue, ptr_ty: Type) InnerError!void {
    const zcu = func.bin_file.comp.module.?;
    const dst_ty = ptr_ty.childType(zcu);

    log.debug("loading {}:{} into {}", .{ ptr_mcv, ptr_ty.fmt(zcu), dst_mcv });

    switch (ptr_mcv) {
        .none,
        .undef,
        .unreach,
        .dead,
        .register_pair,
        .reserved_frame,
        => unreachable, // not a valid pointer

        .immediate,
        .register,
        .register_offset,
        .lea_frame,
        .lea_symbol,
        => try func.genCopy(dst_ty, dst_mcv, ptr_mcv.deref()),

        .memory,
        .indirect,
        .load_symbol,
        .load_frame,
        => {
            const addr_reg = try func.copyToTmpRegister(ptr_ty, ptr_mcv);
            const addr_lock = func.register_manager.lockRegAssumeUnused(addr_reg);
            defer func.register_manager.unlockReg(addr_lock);

            try func.genCopy(dst_ty, dst_mcv, .{ .indirect = .{ .reg = addr_reg } });
        },
        .air_ref => |ptr_ref| try func.load(dst_mcv, try func.resolveInst(ptr_ref), ptr_ty),
    }
}

fn airStore(func: *Func, inst: Air.Inst.Index, safety: bool) !void {
    if (safety) {
        // TODO if the value is undef, write 0xaa bytes to dest
    } else {
        // TODO if the value is undef, don't lower this instruction
    }
    const bin_op = func.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const ptr = try func.resolveInst(bin_op.lhs);
    const value = try func.resolveInst(bin_op.rhs);
    const ptr_ty = func.typeOf(bin_op.lhs);
    const value_ty = func.typeOf(bin_op.rhs);

    try func.store(ptr, value, ptr_ty, value_ty);

    return func.finishAir(inst, .none, .{ bin_op.lhs, bin_op.rhs, .none });
}

/// Loads `value` into the "payload" of `pointer`.
fn store(func: *Func, ptr_mcv: MCValue, src_mcv: MCValue, ptr_ty: Type, src_ty: Type) !void {
    const zcu = func.bin_file.comp.module.?;

    log.debug("storing {}:{} in {}:{}", .{ src_mcv, src_ty.fmt(zcu), ptr_mcv, ptr_ty.fmt(zcu) });

    switch (ptr_mcv) {
        .none => unreachable,
        .undef => unreachable,
        .unreach => unreachable,
        .dead => unreachable,
        .register_pair => unreachable,
        .reserved_frame => unreachable,

        .immediate,
        .register,
        .register_offset,
        .lea_symbol,
        .lea_frame,
        => try func.genCopy(src_ty, ptr_mcv.deref(), src_mcv),

        .memory,
        .indirect,
        .load_symbol,
        .load_frame,
        => {
            const addr_reg = try func.copyToTmpRegister(ptr_ty, ptr_mcv);
            const addr_lock = func.register_manager.lockRegAssumeUnused(addr_reg);
            defer func.register_manager.unlockReg(addr_lock);

            try func.genCopy(src_ty, .{ .indirect = .{ .reg = addr_reg } }, src_mcv);
        },
        .air_ref => |ptr_ref| try func.store(try func.resolveInst(ptr_ref), src_mcv, ptr_ty, src_ty),
    }
}

fn airStructFieldPtr(func: *Func, inst: Air.Inst.Index) !void {
    const ty_pl = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const extra = func.air.extraData(Air.StructField, ty_pl.payload).data;
    const result = try func.structFieldPtr(inst, extra.struct_operand, extra.field_index);
    return func.finishAir(inst, result, .{ extra.struct_operand, .none, .none });
}

fn airStructFieldPtrIndex(func: *Func, inst: Air.Inst.Index, index: u8) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result = try func.structFieldPtr(inst, ty_op.operand, index);
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn structFieldPtr(func: *Func, inst: Air.Inst.Index, operand: Air.Inst.Ref, index: u32) !MCValue {
    const zcu = func.bin_file.comp.module.?;
    const ptr_field_ty = func.typeOfIndex(inst);
    const ptr_container_ty = func.typeOf(operand);
    const ptr_container_ty_info = ptr_container_ty.ptrInfo(zcu);
    const container_ty = ptr_container_ty.childType(zcu);

    const field_offset: i32 = if (zcu.typeToPackedStruct(container_ty)) |struct_obj|
        if (ptr_field_ty.ptrInfo(zcu).packed_offset.host_size == 0)
            @divExact(zcu.structPackedFieldBitOffset(struct_obj, index) +
                ptr_container_ty_info.packed_offset.bit_offset, 8)
        else
            0
    else
        @intCast(container_ty.structFieldOffset(index, zcu));

    const src_mcv = try func.resolveInst(operand);
    const dst_mcv = if (switch (src_mcv) {
        .immediate, .lea_frame => true,
        .register, .register_offset => func.reuseOperand(inst, operand, 0, src_mcv),
        else => false,
    }) src_mcv else try func.copyToNewRegister(inst, src_mcv);
    return dst_mcv.offset(field_offset);
}

fn airStructFieldVal(func: *Func, inst: Air.Inst.Index) !void {
    const mod = func.bin_file.comp.module.?;

    const ty_pl = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const extra = func.air.extraData(Air.StructField, ty_pl.payload).data;
    const operand = extra.struct_operand;
    const index = extra.field_index;

    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else result: {
        const zcu = func.bin_file.comp.module.?;
        const src_mcv = try func.resolveInst(operand);
        const struct_ty = func.typeOf(operand);
        const field_ty = struct_ty.structFieldType(index, zcu);
        if (!field_ty.hasRuntimeBitsIgnoreComptime(zcu)) break :result .none;

        const field_off: u32 = switch (struct_ty.containerLayout(zcu)) {
            .auto, .@"extern" => @intCast(struct_ty.structFieldOffset(index, zcu) * 8),
            .@"packed" => if (zcu.typeToStruct(struct_ty)) |struct_type|
                zcu.structPackedFieldBitOffset(struct_type, index)
            else
                0,
        };

        switch (src_mcv) {
            .dead, .unreach => unreachable,
            .register => |src_reg| {
                const src_reg_lock = func.register_manager.lockRegAssumeUnused(src_reg);
                defer func.register_manager.unlockReg(src_reg_lock);

                const dst_reg = if (field_off == 0)
                    (try func.copyToNewRegister(inst, src_mcv)).register
                else
                    try func.copyToTmpRegister(Type.usize, .{ .register = src_reg });

                const dst_mcv: MCValue = .{ .register = dst_reg };
                const dst_lock = func.register_manager.lockReg(dst_reg);
                defer if (dst_lock) |lock| func.register_manager.unlockReg(lock);

                if (field_off > 0) {
                    _ = try func.addInst(.{
                        .tag = .srli,
                        .ops = .rri,
                        .data = .{ .i_type = .{
                            .imm12 = Immediate.u(@intCast(field_off)),
                            .rd = dst_reg,
                            .rs1 = dst_reg,
                        } },
                    });
                }

                break :result if (field_off == 0) dst_mcv else try func.copyToNewRegister(inst, dst_mcv);
            },
            .load_frame => {
                const field_abi_size: u32 = @intCast(field_ty.abiSize(mod));
                if (field_off % 8 == 0) {
                    const field_byte_off = @divExact(field_off, 8);
                    const off_mcv = src_mcv.address().offset(@intCast(field_byte_off)).deref();
                    const field_bit_size = field_ty.bitSize(mod);

                    if (field_abi_size <= 8) {
                        const int_ty = try mod.intType(
                            if (field_ty.isAbiInt(mod)) field_ty.intInfo(mod).signedness else .unsigned,
                            @intCast(field_bit_size),
                        );

                        const dst_reg, const dst_lock = try func.allocReg(.int);
                        const dst_mcv = MCValue{ .register = dst_reg };
                        defer func.register_manager.unlockReg(dst_lock);

                        try func.genCopy(int_ty, dst_mcv, off_mcv);
                        break :result try func.copyToNewRegister(inst, dst_mcv);
                    }

                    const container_abi_size: u32 = @intCast(struct_ty.abiSize(mod));
                    const dst_mcv = if (field_byte_off + field_abi_size <= container_abi_size and
                        func.reuseOperand(inst, operand, 0, src_mcv))
                        off_mcv
                    else dst: {
                        const dst_mcv = try func.allocRegOrMem(func.typeOfIndex(inst), inst, true);
                        try func.genCopy(field_ty, dst_mcv, off_mcv);
                        break :dst dst_mcv;
                    };
                    if (field_abi_size * 8 > field_bit_size and dst_mcv.isMemory()) {
                        const tmp_reg, const tmp_lock = try func.allocReg(.int);
                        defer func.register_manager.unlockReg(tmp_lock);

                        const hi_mcv =
                            dst_mcv.address().offset(@intCast(field_bit_size / 64 * 8)).deref();
                        try func.genSetReg(Type.usize, tmp_reg, hi_mcv);
                        try func.genCopy(Type.usize, hi_mcv, .{ .register = tmp_reg });
                    }
                    break :result dst_mcv;
                }

                return func.fail("TODO: airStructFieldVal load_frame field_off non multiple of 8", .{});
            },
            else => return func.fail("TODO: airStructField {s}", .{@tagName(src_mcv)}),
        }
    };

    return func.finishAir(inst, result, .{ extra.struct_operand, .none, .none });
}

fn airFieldParentPtr(func: *Func, inst: Air.Inst.Index) !void {
    _ = inst;
    return func.fail("TODO implement codegen airFieldParentPtr", .{});
}

fn genArgDbgInfo(func: Func, inst: Air.Inst.Index, mcv: MCValue) !void {
    const zcu = func.bin_file.comp.module.?;
    const arg = func.air.instructions.items(.data)[@intFromEnum(inst)].arg;
    const ty = arg.ty.toType();
    const owner_decl = zcu.funcOwnerDeclIndex(func.func_index);
    const name = zcu.getParamName(func.func_index, arg.src_index);

    switch (func.debug_output) {
        .dwarf => |dw| switch (mcv) {
            .register => |reg| try dw.genArgDbgInfo(name, ty, owner_decl, .{
                .register = reg.dwarfLocOp(),
            }),
            .load_frame => {},
            else => {},
        },
        .plan9 => {},
        .none => {},
    }
}

fn airArg(func: *Func, inst: Air.Inst.Index) !void {
    var arg_index = func.arg_index;

    // we skip over args that have no bits
    while (func.args[arg_index] == .none) arg_index += 1;
    func.arg_index = arg_index + 1;

    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else result: {
        const src_mcv = func.args[arg_index];
        const arg_ty = func.typeOfIndex(inst);

        const dst_mcv = try func.allocRegOrMem(arg_ty, inst, false);

        log.debug("airArg {} -> {}", .{ src_mcv, dst_mcv });

        try func.genCopy(arg_ty, dst_mcv, src_mcv);

        try func.genArgDbgInfo(inst, src_mcv);
        break :result dst_mcv;
    };

    return func.finishAir(inst, result, .{ .none, .none, .none });
}

fn airTrap(func: *Func) !void {
    _ = try func.addInst(.{
        .tag = .unimp,
        .ops = .none,
        .data = undefined,
    });
    return func.finishAirBookkeeping();
}

fn airBreakpoint(func: *Func) !void {
    _ = try func.addInst(.{
        .tag = .ebreak,
        .ops = .none,
        .data = undefined,
    });
    return func.finishAirBookkeeping();
}

fn airRetAddr(func: *Func, inst: Air.Inst.Index) !void {
    const dst_mcv = try func.allocRegOrMem(func.typeOfIndex(inst), inst, true);
    try func.genCopy(Type.usize, dst_mcv, .{ .load_frame = .{ .index = .ret_addr } });
    return func.finishAir(inst, dst_mcv, .{ .none, .none, .none });
}

fn airFrameAddress(func: *Func, inst: Air.Inst.Index) !void {
    const dst_mcv = try func.allocRegOrMem(func.typeOfIndex(inst), inst, true);
    try func.genCopy(Type.usize, dst_mcv, .{ .lea_frame = .{ .index = .base_ptr } });
    return func.finishAir(inst, dst_mcv, .{ .none, .none, .none });
}

fn airFence(func: *Func) !void {
    return func.fail("TODO implement fence() for {}", .{func.target.cpu.arch});
    //return func.finishAirBookkeeping();
}

fn airCall(func: *Func, inst: Air.Inst.Index, modifier: std.builtin.CallModifier) !void {
    if (modifier == .always_tail) return func.fail("TODO implement tail calls for riscv64", .{});
    const pl_op = func.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
    const callee = pl_op.operand;
    const extra = func.air.extraData(Air.Call, pl_op.payload);
    const arg_refs: []const Air.Inst.Ref = @ptrCast(func.air.extra[extra.end..][0..extra.data.args_len]);

    const expected_num_args = 8;
    const ExpectedContents = extern struct {
        vals: [expected_num_args][@sizeOf(MCValue)]u8 align(@alignOf(MCValue)),
    };
    var stack align(@max(@alignOf(ExpectedContents), @alignOf(std.heap.StackFallbackAllocator(0)))) =
        std.heap.stackFallback(@sizeOf(ExpectedContents), func.gpa);
    const allocator = stack.get();

    const arg_tys = try allocator.alloc(Type, arg_refs.len);
    defer allocator.free(arg_tys);
    for (arg_tys, arg_refs) |*arg_ty, arg_ref| arg_ty.* = func.typeOf(arg_ref);

    const arg_vals = try allocator.alloc(MCValue, arg_refs.len);
    defer allocator.free(arg_vals);
    for (arg_vals, arg_refs) |*arg_val, arg_ref| arg_val.* = .{ .air_ref = arg_ref };

    const call_ret = try func.genCall(.{ .air = callee }, arg_tys, arg_vals);

    var bt = func.liveness.iterateBigTomb(inst);
    try func.feed(&bt, pl_op.operand);
    for (arg_refs) |arg_ref| try func.feed(&bt, arg_ref);

    const result = if (func.liveness.isUnused(inst)) .unreach else call_ret;
    return func.finishAirResult(inst, result);
}

fn genCall(
    func: *Func,
    info: union(enum) {
        air: Air.Inst.Ref,
        lib: struct {
            return_type: InternPool.Index,
            param_types: []const InternPool.Index,
            lib: ?[]const u8 = null,
            callee: []const u8,
        },
    },
    arg_tys: []const Type,
    args: []const MCValue,
) !MCValue {
    const zcu = func.bin_file.comp.module.?;

    const fn_ty = switch (info) {
        .air => |callee| fn_info: {
            const callee_ty = func.typeOf(callee);
            break :fn_info switch (callee_ty.zigTypeTag(zcu)) {
                .Fn => callee_ty,
                .Pointer => callee_ty.childType(zcu),
                else => unreachable,
            };
        },
        .lib => |lib| try zcu.funcType(.{
            .param_types = lib.param_types,
            .return_type = lib.return_type,
            .cc = .C,
        }),
    };

    const fn_info = zcu.typeToFunc(fn_ty).?;

    const allocator = func.gpa;

    const var_args = try allocator.alloc(Type, args.len - fn_info.param_types.len);
    defer allocator.free(var_args);
    for (var_args, arg_tys[fn_info.param_types.len..]) |*var_arg, arg_ty| var_arg.* = arg_ty;

    var call_info = try func.resolveCallingConventionValues(fn_info, var_args);
    defer call_info.deinit(func);

    // We need a properly aligned and sized call frame to be able to call this function.
    {
        const needed_call_frame = FrameAlloc.init(.{
            .size = call_info.stack_byte_count,
            .alignment = call_info.stack_align,
        });
        const frame_allocs_slice = func.frame_allocs.slice();
        const stack_frame_size =
            &frame_allocs_slice.items(.abi_size)[@intFromEnum(FrameIndex.call_frame)];
        stack_frame_size.* = @max(stack_frame_size.*, needed_call_frame.abi_size);
        const stack_frame_align =
            &frame_allocs_slice.items(.abi_align)[@intFromEnum(FrameIndex.call_frame)];
        stack_frame_align.* = stack_frame_align.max(needed_call_frame.abi_align);
    }

    var reg_locks = std.ArrayList(?RegisterLock).init(allocator);
    defer reg_locks.deinit();
    try reg_locks.ensureTotalCapacity(8);
    defer for (reg_locks.items) |reg_lock| if (reg_lock) |lock| func.register_manager.unlockReg(lock);

    const frame_indices = try allocator.alloc(FrameIndex, args.len);
    defer allocator.free(frame_indices);

    switch (call_info.return_value.long) {
        .none, .unreach => {},
        .indirect => |reg_off| try func.register_manager.getReg(reg_off.reg, null),
        else => unreachable,
    }
    for (call_info.args, args, arg_tys, frame_indices) |dst_arg, src_arg, arg_ty, *frame_index| {
        switch (dst_arg) {
            .none => {},
            .register => |reg| {
                try func.register_manager.getReg(reg, null);
                try reg_locks.append(func.register_manager.lockReg(reg));
            },
            .register_pair => |regs| {
                for (regs) |reg| try func.register_manager.getReg(reg, null);
                try reg_locks.appendSlice(&func.register_manager.lockRegs(2, regs));
            },
            .indirect => |reg_off| {
                frame_index.* = try func.allocFrameIndex(FrameAlloc.initType(arg_ty, zcu));
                try func.genSetMem(.{ .frame = frame_index.* }, 0, arg_ty, src_arg);
                try func.register_manager.getReg(reg_off.reg, null);
                try reg_locks.append(func.register_manager.lockReg(reg_off.reg));
            },
            else => return func.fail("TODO: genCall set arg {s}", .{@tagName(dst_arg)}),
        }
    }

    switch (call_info.return_value.long) {
        .none, .unreach => {},
        .indirect => |reg_off| {
            const ret_ty = Type.fromInterned(fn_info.return_type);
            const frame_index = try func.allocFrameIndex(FrameAlloc.initSpill(ret_ty, zcu));
            try func.genSetReg(Type.usize, reg_off.reg, .{
                .lea_frame = .{ .index = frame_index, .off = -reg_off.off },
            });
            call_info.return_value.short = .{ .load_frame = .{ .index = frame_index } };
            try reg_locks.append(func.register_manager.lockReg(reg_off.reg));
        },
        else => unreachable,
    }

    for (call_info.args, arg_tys, args, frame_indices) |dst_arg, arg_ty, src_arg, frame_index| {
        switch (dst_arg) {
            .none, .load_frame => {},
            .register_pair => try func.genCopy(arg_ty, dst_arg, src_arg),
            .register => |dst_reg| try func.genSetReg(
                arg_ty,
                dst_reg,
                src_arg,
            ),
            .indirect => |reg_off| try func.genSetReg(Type.usize, reg_off.reg, .{
                .lea_frame = .{ .index = frame_index, .off = -reg_off.off },
            }),
            else => return func.fail("TODO: genCall actual set {s}", .{@tagName(dst_arg)}),
        }
    }

    // Due to incremental compilation, how function calls are generated depends
    // on linking.
    switch (info) {
        .air => |callee| {
            if (try func.air.value(callee, zcu)) |func_value| {
                const func_key = zcu.intern_pool.indexToKey(func_value.ip_index);
                switch (switch (func_key) {
                    else => func_key,
                    .ptr => |ptr| if (ptr.byte_offset == 0) switch (ptr.base_addr) {
                        .decl => |decl| zcu.intern_pool.indexToKey(zcu.declPtr(decl).val.toIntern()),
                        else => func_key,
                    } else func_key,
                }) {
                    .func => |func_val| {
                        if (func.bin_file.cast(link.File.Elf)) |elf_file| {
                            const sym_index = try elf_file.zigObjectPtr().?.getOrCreateMetadataForDecl(elf_file, func_val.owner_decl);
                            const sym = elf_file.symbol(sym_index);

                            if (func.mod.pic) {
                                return func.fail("TODO: genCall pic", .{});
                            } else {
                                try func.genSetReg(Type.usize, .ra, .{ .load_symbol = .{ .sym = sym.esym_index } });
                                _ = try func.addInst(.{
                                    .tag = .jalr,
                                    .ops = .rri,
                                    .data = .{ .i_type = .{
                                        .rd = .ra,
                                        .rs1 = .ra,
                                        .imm12 = Immediate.s(0),
                                    } },
                                });
                            }
                        } else unreachable; // not a valid riscv64 format
                    },
                    .extern_func => |extern_func| {
                        const owner_decl = zcu.declPtr(extern_func.decl);
                        const lib_name = extern_func.lib_name.toSlice(&zcu.intern_pool);
                        const decl_name = owner_decl.name.toSlice(&zcu.intern_pool);
                        const atom_index = try func.symbolIndex();

                        if (func.bin_file.cast(link.File.Elf)) |elf_file| {
                            _ = try func.addInst(.{
                                .tag = .pseudo,
                                .ops = .pseudo_extern_fn_reloc,
                                .data = .{ .reloc = .{
                                    .atom_index = atom_index,
                                    .sym_index = try elf_file.getGlobalSymbol(decl_name, lib_name),
                                } },
                            });
                        } else unreachable; // not a valid riscv64 format
                    },
                    else => return func.fail("TODO implement calling bitcasted functions", .{}),
                }
            } else {
                assert(func.typeOf(callee).zigTypeTag(zcu) == .Pointer);
                const addr_reg, const addr_lock = try func.allocReg(.int);
                defer func.register_manager.unlockReg(addr_lock);
                try func.genSetReg(Type.usize, addr_reg, .{ .air_ref = callee });

                _ = try func.addInst(.{
                    .tag = .jalr,
                    .ops = .rri,
                    .data = .{ .i_type = .{
                        .rd = .ra,
                        .rs1 = addr_reg,
                        .imm12 = Immediate.s(0),
                    } },
                });
            }
        },
        .lib => return func.fail("TODO: lib func calls", .{}),
    }

    return call_info.return_value.short;
}

fn airRet(func: *Func, inst: Air.Inst.Index, safety: bool) !void {
    const zcu = func.bin_file.comp.module.?;
    const un_op = func.air.instructions.items(.data)[@intFromEnum(inst)].un_op;

    if (safety) {
        // safe
    } else {
        // not safe
    }

    const ret_ty = func.fn_type.fnReturnType(zcu);
    switch (func.ret_mcv.short) {
        .none => {},
        .register,
        .register_pair,
        => try func.genCopy(ret_ty, func.ret_mcv.short, .{ .air_ref = un_op }),
        .indirect => |reg_off| {
            try func.register_manager.getReg(reg_off.reg, null);
            const lock = func.register_manager.lockRegAssumeUnused(reg_off.reg);
            defer func.register_manager.unlockReg(lock);

            try func.genSetReg(Type.usize, reg_off.reg, func.ret_mcv.long);
            try func.genSetMem(
                .{ .reg = reg_off.reg },
                reg_off.off,
                ret_ty,
                .{ .air_ref = un_op },
            );
        },
        else => unreachable,
    }

    func.ret_mcv.liveOut(func, inst);
    try func.finishAir(inst, .unreach, .{ un_op, .none, .none });

    // Just add space for an instruction, reloced this later
    const index = try func.addInst(.{
        .tag = .pseudo,
        .ops = .pseudo_j,
        .data = .{ .inst = undefined },
    });

    try func.exitlude_jump_relocs.append(func.gpa, index);
}

fn airRetLoad(func: *Func, inst: Air.Inst.Index) !void {
    const un_op = func.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const ptr = try func.resolveInst(un_op);

    const ptr_ty = func.typeOf(un_op);
    switch (func.ret_mcv.short) {
        .none => {},
        .register, .register_pair => try func.load(func.ret_mcv.short, ptr, ptr_ty),
        .indirect => |reg_off| try func.genSetReg(ptr_ty, reg_off.reg, ptr),
        else => unreachable,
    }
    func.ret_mcv.liveOut(func, inst);
    try func.finishAir(inst, .unreach, .{ un_op, .none, .none });

    // Just add space for an instruction, reloced this later
    const index = try func.addInst(.{
        .tag = .pseudo,
        .ops = .pseudo_j,
        .data = .{ .inst = undefined },
    });

    try func.exitlude_jump_relocs.append(func.gpa, index);
}

fn airCmp(func: *Func, inst: Air.Inst.Index, tag: Air.Inst.Tag) !void {
    const bin_op = func.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const zcu = func.bin_file.comp.module.?;

    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else result: {
        const lhs_ty = func.typeOf(bin_op.lhs);

        switch (lhs_ty.zigTypeTag(zcu)) {
            .Int,
            .Enum,
            .Bool,
            .Pointer,
            .ErrorSet,
            .Optional,
            => {
                const int_ty = switch (lhs_ty.zigTypeTag(zcu)) {
                    .Enum => lhs_ty.intTagType(zcu),
                    .Int => lhs_ty,
                    .Bool => Type.u1,
                    .Pointer => Type.usize,
                    .ErrorSet => Type.anyerror,
                    .Optional => blk: {
                        const payload_ty = lhs_ty.optionalChild(zcu);
                        if (!payload_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
                            break :blk Type.u1;
                        } else if (lhs_ty.isPtrLikeOptional(zcu)) {
                            break :blk Type.usize;
                        } else {
                            return func.fail("TODO riscv cmp non-pointer optionals", .{});
                        }
                    },
                    else => unreachable,
                };

                const int_info = int_ty.intInfo(zcu);
                if (int_info.bits <= 64) {
                    break :result try func.binOp(inst, tag, bin_op.lhs, bin_op.rhs);
                } else {
                    return func.fail("TODO riscv cmp for ints > 64 bits", .{});
                }
            },
            .Float => {
                const float_bits = lhs_ty.floatBits(func.target.*);
                const float_reg_size: u32 = if (func.hasFeature(.d)) 64 else 32;
                if (float_bits > float_reg_size) {
                    return func.fail("TODO: airCmp float > 64/32 bits", .{});
                }
                break :result try func.binOp(inst, tag, bin_op.lhs, bin_op.rhs);
            },
            else => unreachable,
        }
    };

    return func.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airCmpVector(func: *Func, inst: Air.Inst.Index) !void {
    _ = inst;
    return func.fail("TODO implement airCmpVector for {}", .{func.target.cpu.arch});
}

fn airCmpLtErrorsLen(func: *Func, inst: Air.Inst.Index) !void {
    const un_op = func.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const operand = try func.resolveInst(un_op);
    _ = operand;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airCmpLtErrorsLen for {}", .{func.target.cpu.arch});
    return func.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airDbgStmt(func: *Func, inst: Air.Inst.Index) !void {
    const dbg_stmt = func.air.instructions.items(.data)[@intFromEnum(inst)].dbg_stmt;

    _ = try func.addInst(.{
        .tag = .pseudo,
        .ops = .pseudo_dbg_line_column,
        .data = .{ .pseudo_dbg_line_column = .{
            .line = dbg_stmt.line,
            .column = dbg_stmt.column,
        } },
    });

    return func.finishAirBookkeeping();
}

fn airDbgInlineBlock(func: *Func, inst: Air.Inst.Index) !void {
    const ty_pl = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const extra = func.air.extraData(Air.DbgInlineBlock, ty_pl.payload);
    try func.lowerBlock(inst, @ptrCast(func.air.extra[extra.end..][0..extra.data.body_len]));
}

fn airDbgVar(func: *Func, inst: Air.Inst.Index) !void {
    const pl_op = func.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
    const operand = pl_op.operand;
    const ty = func.typeOf(operand);
    const mcv = try func.resolveInst(operand);

    const name = func.air.nullTerminatedString(pl_op.payload);

    const tag = func.air.instructions.items(.tag)[@intFromEnum(inst)];
    try func.genVarDbgInfo(tag, ty, mcv, name);

    return func.finishAir(inst, .unreach, .{ operand, .none, .none });
}

fn genVarDbgInfo(
    func: Func,
    tag: Air.Inst.Tag,
    ty: Type,
    mcv: MCValue,
    name: [:0]const u8,
) !void {
    const zcu = func.bin_file.comp.module.?;
    const is_ptr = switch (tag) {
        .dbg_var_ptr => true,
        .dbg_var_val => false,
        else => unreachable,
    };

    switch (func.debug_output) {
        .dwarf => |dw| {
            const loc: link.File.Dwarf.DeclState.DbgInfoLoc = switch (mcv) {
                .register => |reg| .{ .register = reg.dwarfLocOp() },
                .memory => |address| .{ .memory = address },
                .load_symbol => |sym_off| loc: {
                    assert(sym_off.off == 0);
                    break :loc .{ .linker_load = .{ .type = .direct, .sym_index = sym_off.sym } };
                },
                .immediate => |x| .{ .immediate = x },
                .undef => .undef,
                .none => .none,
                else => blk: {
                    // log.warn("TODO generate debug info for {}", .{mcv});
                    break :blk .nop;
                },
            };
            try dw.genVarDbgInfo(name, ty, zcu.funcOwnerDeclIndex(func.func_index), is_ptr, loc);
        },
        .plan9 => {},
        .none => {},
    }
}

fn airCondBr(func: *Func, inst: Air.Inst.Index) !void {
    const pl_op = func.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
    const cond = try func.resolveInst(pl_op.operand);
    const cond_ty = func.typeOf(pl_op.operand);
    const extra = func.air.extraData(Air.CondBr, pl_op.payload);
    const then_body: []const Air.Inst.Index = @ptrCast(func.air.extra[extra.end..][0..extra.data.then_body_len]);
    const else_body: []const Air.Inst.Index = @ptrCast(func.air.extra[extra.end + then_body.len ..][0..extra.data.else_body_len]);
    const liveness_cond_br = func.liveness.getCondBr(inst);

    // If the condition dies here in this condbr instruction, process
    // that death now instead of later as this has an effect on
    // whether it needs to be spilled in the branches
    if (func.liveness.operandDies(inst, 0)) {
        if (pl_op.operand.toIndex()) |op_inst| try func.processDeath(op_inst);
    }

    func.scope_generation += 1;
    const state = try func.saveState();
    const reloc = try func.condBr(cond_ty, cond);

    for (liveness_cond_br.then_deaths) |death| try func.processDeath(death);
    try func.genBody(then_body);
    try func.restoreState(state, &.{}, .{
        .emit_instructions = false,
        .update_tracking = true,
        .resurrect = true,
        .close_scope = true,
    });

    func.performReloc(reloc);

    for (liveness_cond_br.else_deaths) |death| try func.processDeath(death);
    try func.genBody(else_body);
    try func.restoreState(state, &.{}, .{
        .emit_instructions = false,
        .update_tracking = true,
        .resurrect = true,
        .close_scope = true,
    });

    // We already took care of pl_op.operand earlier, so there's nothing left to do.
    func.finishAirBookkeeping();
}

fn condBr(func: *Func, cond_ty: Type, condition: MCValue) !Mir.Inst.Index {
    const cond_reg = try func.copyToTmpRegister(cond_ty, condition);

    return try func.addInst(.{
        .tag = .beq,
        .ops = .rr_inst,
        .data = .{
            .b_type = .{
                .rs1 = cond_reg,
                .rs2 = .zero,
                .inst = undefined,
            },
        },
    });
}

fn isNull(func: *Func, inst: Air.Inst.Index, opt_ty: Type, opt_mcv: MCValue) !MCValue {
    const zcu = func.bin_file.comp.module.?;
    const pl_ty = opt_ty.optionalChild(zcu);

    const some_info: struct { off: i32, ty: Type } = if (opt_ty.optionalReprIsPayload(zcu))
        .{ .off = 0, .ty = if (pl_ty.isSlice(zcu)) pl_ty.slicePtrFieldType(zcu) else pl_ty }
    else
        .{ .off = @intCast(pl_ty.abiSize(zcu)), .ty = Type.bool };

    const return_mcv = try func.allocRegOrMem(func.typeOfIndex(inst), inst, true);
    assert(return_mcv == .register); // should not be larger 8 bytes
    const return_reg = return_mcv.register;

    switch (opt_mcv) {
        .none,
        .unreach,
        .dead,
        .undef,
        .immediate,
        .register_pair,
        .register_offset,
        .lea_frame,
        .lea_symbol,
        .reserved_frame,
        .air_ref,
        => return func.fail("TODO: hmm {}", .{opt_mcv}),

        .register => |opt_reg| {
            if (some_info.off == 0) {
                _ = try func.addInst(.{
                    .tag = .pseudo,
                    .ops = .pseudo_compare,
                    .data = .{
                        .compare = .{
                            .op = .eq,
                            .rd = return_reg,
                            .rs1 = opt_reg,
                            .rs2 = try func.copyToTmpRegister(
                                some_info.ty,
                                .{ .immediate = 0 },
                            ),
                            .ty = Type.bool,
                        },
                    },
                });
                return return_mcv;
            }
            assert(some_info.ty.ip_index == .bool_type);
            const opt_abi_size: u32 = @intCast(opt_ty.abiSize(zcu));
            _ = opt_abi_size;
            return func.fail("TODO: isNull some_info.off != 0 register", .{});
        },

        .load_frame => {
            const opt_reg = try func.copyToTmpRegister(
                some_info.ty,
                opt_mcv.address().offset(some_info.off).deref(),
            );
            const opt_reg_lock = func.register_manager.lockRegAssumeUnused(opt_reg);
            defer func.register_manager.unlockReg(opt_reg_lock);

            _ = try func.addInst(.{
                .tag = .pseudo,
                .ops = .pseudo_compare,
                .data = .{
                    .compare = .{
                        .op = .eq,
                        .rd = return_reg,
                        .rs1 = opt_reg,
                        .rs2 = try func.copyToTmpRegister(
                            some_info.ty,
                            .{ .immediate = 0 },
                        ),
                        .ty = Type.bool,
                    },
                },
            });
            return return_mcv;
        },

        else => return func.fail("TODO: isNull {}", .{opt_mcv}),
    }
}

fn airIsNull(func: *Func, inst: Air.Inst.Index) !void {
    const un_op = func.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const operand = try func.resolveInst(un_op);
    const ty = func.typeOf(un_op);
    const result = try func.isNull(inst, ty, operand);
    return func.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airIsNullPtr(func: *Func, inst: Air.Inst.Index) !void {
    const un_op = func.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const operand = try func.resolveInst(un_op);
    _ = operand;
    const ty = func.typeOf(un_op);
    _ = ty;

    if (true) return func.fail("TODO: airIsNullPtr", .{});

    return func.finishAir(inst, .unreach, .{ un_op, .none, .none });
}

fn airIsNonNull(func: *Func, inst: Air.Inst.Index) !void {
    const un_op = func.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const operand = try func.resolveInst(un_op);
    const ty = func.typeOf(un_op);
    const result = try func.isNull(inst, ty, operand);
    assert(result == .register);

    _ = try func.addInst(.{
        .tag = .pseudo,
        .ops = .pseudo_not,
        .data = .{
            .rr = .{
                .rd = result.register,
                .rs = result.register,
            },
        },
    });

    return func.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airIsNonNullPtr(func: *Func, inst: Air.Inst.Index) !void {
    const un_op = func.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const operand = try func.resolveInst(un_op);
    _ = operand;
    const ty = func.typeOf(un_op);
    _ = ty;

    if (true) return func.fail("TODO: airIsNonNullPtr", .{});

    return func.finishAir(inst, .unreach, .{ un_op, .none, .none });
}

fn airIsErr(func: *Func, inst: Air.Inst.Index) !void {
    const un_op = func.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else result: {
        const operand = try func.resolveInst(un_op);
        const operand_ty = func.typeOf(un_op);
        break :result try func.isErr(inst, operand_ty, operand);
    };
    return func.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airIsErrPtr(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const un_op = func.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else result: {
        const operand_ptr = try func.resolveInst(un_op);
        const operand: MCValue = blk: {
            if (func.reuseOperand(inst, un_op, 0, operand_ptr)) {
                // The MCValue that holds the pointer can be re-used as the value.
                break :blk operand_ptr;
            } else {
                break :blk try func.allocRegOrMem(func.typeOfIndex(inst), inst, true);
            }
        };
        try func.load(operand, operand_ptr, func.typeOf(un_op));
        const operand_ptr_ty = func.typeOf(un_op);
        const operand_ty = operand_ptr_ty.childType(zcu);

        break :result try func.isErr(inst, operand_ty, operand);
    };
    return func.finishAir(inst, result, .{ un_op, .none, .none });
}

/// Generates a compare instruction which will indicate if `eu_mcv` is an error.
///
/// Result is in the return register.
fn isErr(func: *Func, maybe_inst: ?Air.Inst.Index, eu_ty: Type, eu_mcv: MCValue) !MCValue {
    _ = maybe_inst;
    const zcu = func.bin_file.comp.module.?;
    const err_ty = eu_ty.errorUnionSet(zcu);
    if (err_ty.errorSetIsEmpty(zcu)) return MCValue{ .immediate = 0 }; // always false
    const err_off: u31 = @intCast(errUnionErrorOffset(eu_ty.errorUnionPayload(zcu), zcu));

    const return_reg, const return_lock = try func.allocReg(.int);
    defer func.register_manager.unlockReg(return_lock);

    switch (eu_mcv) {
        .register => |reg| {
            const eu_lock = func.register_manager.lockReg(reg);
            defer if (eu_lock) |lock| func.register_manager.unlockReg(lock);

            try func.genCopy(eu_ty, .{ .register = return_reg }, eu_mcv);

            if (err_off > 0) {
                try func.genBinOp(
                    .shr,
                    .{ .register = return_reg },
                    eu_ty,
                    .{ .immediate = @as(u6, @intCast(err_off * 8)) },
                    Type.u8,
                    return_reg,
                );
            }

            try func.genBinOp(
                .cmp_neq,
                .{ .register = return_reg },
                Type.anyerror,
                .{ .immediate = 0 },
                Type.u8,
                return_reg,
            );
        },
        .load_frame => |frame_addr| {
            try func.genBinOp(
                .cmp_neq,
                .{ .load_frame = .{
                    .index = frame_addr.index,
                    .off = frame_addr.off + err_off,
                } },
                Type.anyerror,
                .{ .immediate = 0 },
                Type.anyerror,
                return_reg,
            );
        },
        else => return func.fail("TODO implement isErr for {}", .{eu_mcv}),
    }

    return .{ .register = return_reg };
}

fn airIsNonErr(func: *Func, inst: Air.Inst.Index) !void {
    const un_op = func.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else result: {
        const operand = try func.resolveInst(un_op);
        const ty = func.typeOf(un_op);
        break :result try func.isNonErr(inst, ty, operand);
    };
    return func.finishAir(inst, result, .{ un_op, .none, .none });
}

fn isNonErr(func: *Func, inst: Air.Inst.Index, eu_ty: Type, eu_mcv: MCValue) !MCValue {
    const is_err_res = try func.isErr(inst, eu_ty, eu_mcv);
    switch (is_err_res) {
        .register => |reg| {
            _ = try func.addInst(.{
                .tag = .pseudo,
                .ops = .pseudo_not,
                .data = .{
                    .rr = .{
                        .rd = reg,
                        .rs = reg,
                    },
                },
            });
            return is_err_res;
        },
        // always false case
        .immediate => |imm| {
            assert(imm == 0);
            return MCValue{ .immediate = @intFromBool(imm == 0) };
        },
        else => unreachable,
    }
}

fn airIsNonErrPtr(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const un_op = func.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else result: {
        const operand_ptr = try func.resolveInst(un_op);
        const operand: MCValue = blk: {
            if (func.reuseOperand(inst, un_op, 0, operand_ptr)) {
                // The MCValue that holds the pointer can be re-used as the value.
                break :blk operand_ptr;
            } else {
                break :blk try func.allocRegOrMem(func.typeOfIndex(inst), inst, true);
            }
        };
        const operand_ptr_ty = func.typeOf(un_op);
        const operand_ty = operand_ptr_ty.childType(zcu);

        try func.load(operand, operand_ptr, func.typeOf(un_op));
        break :result try func.isNonErr(inst, operand_ty, operand);
    };
    return func.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airLoop(func: *Func, inst: Air.Inst.Index) !void {
    // A loop is a setup to be able to jump back to the beginning.
    const ty_pl = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const loop = func.air.extraData(Air.Block, ty_pl.payload);
    const body: []const Air.Inst.Index = @ptrCast(func.air.extra[loop.end..][0..loop.data.body_len]);

    func.scope_generation += 1;
    const state = try func.saveState();

    const jmp_target: Mir.Inst.Index = @intCast(func.mir_instructions.len);
    try func.genBody(body);
    try func.restoreState(state, &.{}, .{
        .emit_instructions = true,
        .update_tracking = false,
        .resurrect = false,
        .close_scope = true,
    });
    _ = try func.jump(jmp_target);

    func.finishAirBookkeeping();
}

/// Send control flow to the `index` of `func.code`.
fn jump(func: *Func, index: Mir.Inst.Index) !Mir.Inst.Index {
    return func.addInst(.{
        .tag = .pseudo,
        .ops = .pseudo_j,
        .data = .{
            .inst = index,
        },
    });
}

fn airBlock(func: *Func, inst: Air.Inst.Index) !void {
    const ty_pl = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const extra = func.air.extraData(Air.Block, ty_pl.payload);
    try func.lowerBlock(inst, @ptrCast(func.air.extra[extra.end..][0..extra.data.body_len]));
}

fn lowerBlock(func: *Func, inst: Air.Inst.Index, body: []const Air.Inst.Index) !void {
    // A block is a setup to be able to jump to the end.
    const inst_tracking_i = func.inst_tracking.count();
    func.inst_tracking.putAssumeCapacityNoClobber(inst, InstTracking.init(.unreach));

    func.scope_generation += 1;
    try func.blocks.putNoClobber(func.gpa, inst, .{ .state = func.initRetroactiveState() });
    const liveness = func.liveness.getBlock(inst);

    // TODO emit debug info lexical block
    try func.genBody(body);

    var block_data = func.blocks.fetchRemove(inst).?;
    defer block_data.value.deinit(func.gpa);
    if (block_data.value.relocs.items.len > 0) {
        try func.restoreState(block_data.value.state, liveness.deaths, .{
            .emit_instructions = false,
            .update_tracking = true,
            .resurrect = true,
            .close_scope = true,
        });
        for (block_data.value.relocs.items) |reloc| func.performReloc(reloc);
    }

    if (std.debug.runtime_safety) assert(func.inst_tracking.getIndex(inst).? == inst_tracking_i);
    const tracking = &func.inst_tracking.values()[inst_tracking_i];
    if (func.liveness.isUnused(inst)) try tracking.die(func, inst);
    func.getValueIfFree(tracking.short, inst);
    func.finishAirBookkeeping();
}

fn airSwitchBr(func: *Func, inst: Air.Inst.Index) !void {
    const pl_op = func.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
    const condition = try func.resolveInst(pl_op.operand);
    const condition_ty = func.typeOf(pl_op.operand);
    const switch_br = func.air.extraData(Air.SwitchBr, pl_op.payload);
    var extra_index: usize = switch_br.end;
    var case_i: u32 = 0;
    const liveness = try func.liveness.getSwitchBr(func.gpa, inst, switch_br.data.cases_len + 1);
    defer func.gpa.free(liveness.deaths);

    // If the condition dies here in this switch instruction, process
    // that death now instead of later as this has an effect on
    // whether it needs to be spilled in the branches
    if (func.liveness.operandDies(inst, 0)) {
        if (pl_op.operand.toIndex()) |op_inst| try func.processDeath(op_inst);
    }

    func.scope_generation += 1;
    const state = try func.saveState();

    while (case_i < switch_br.data.cases_len) : (case_i += 1) {
        const case = func.air.extraData(Air.SwitchBr.Case, extra_index);
        const items: []const Air.Inst.Ref =
            @ptrCast(func.air.extra[case.end..][0..case.data.items_len]);
        const case_body: []const Air.Inst.Index =
            @ptrCast(func.air.extra[case.end + items.len ..][0..case.data.body_len]);
        extra_index = case.end + items.len + case_body.len;

        var relocs = try func.gpa.alloc(Mir.Inst.Index, items.len);
        defer func.gpa.free(relocs);

        for (items, relocs, 0..) |item, *reloc, i| {
            // switch branches must be comptime-known, so this is stored in an immediate
            const item_mcv = try func.resolveInst(item);

            const cmp_reg, const cmp_lock = try func.allocReg(.int);
            defer func.register_manager.unlockReg(cmp_lock);

            try func.genBinOp(
                .cmp_neq,
                condition,
                condition_ty,
                item_mcv,
                condition_ty,
                cmp_reg,
            );

            if (!(i < relocs.len - 1)) {
                _ = try func.addInst(.{
                    .tag = .pseudo,
                    .ops = .pseudo_not,
                    .data = .{ .rr = .{
                        .rd = cmp_reg,
                        .rs = cmp_reg,
                    } },
                });
            }

            reloc.* = try func.condBr(condition_ty, .{ .register = cmp_reg });
        }

        for (liveness.deaths[case_i]) |operand| try func.processDeath(operand);

        for (relocs[0 .. relocs.len - 1]) |reloc| func.performReloc(reloc);
        try func.genBody(case_body);
        try func.restoreState(state, &.{}, .{
            .emit_instructions = false,
            .update_tracking = true,
            .resurrect = true,
            .close_scope = true,
        });

        func.performReloc(relocs[relocs.len - 1]);
    }

    if (switch_br.data.else_body_len > 0) {
        const else_body: []const Air.Inst.Index =
            @ptrCast(func.air.extra[extra_index..][0..switch_br.data.else_body_len]);

        const else_deaths = liveness.deaths.len - 1;
        for (liveness.deaths[else_deaths]) |operand| try func.processDeath(operand);

        try func.genBody(else_body);
        try func.restoreState(state, &.{}, .{
            .emit_instructions = false,
            .update_tracking = true,
            .resurrect = true,
            .close_scope = true,
        });
    }

    // We already took care of pl_op.operand earlier, so there's nothing left to do
    func.finishAirBookkeeping();
}

fn performReloc(func: *Func, inst: Mir.Inst.Index) void {
    const tag = func.mir_instructions.items(.tag)[inst];
    const ops = func.mir_instructions.items(.ops)[inst];
    const target: Mir.Inst.Index = @intCast(func.mir_instructions.len);

    switch (tag) {
        .bne,
        .beq,
        => func.mir_instructions.items(.data)[inst].b_type.inst = target,
        .jal => func.mir_instructions.items(.data)[inst].j_type.inst = target,
        .pseudo => switch (ops) {
            .pseudo_j => func.mir_instructions.items(.data)[inst].inst = target,
            else => std.debug.panic("TODO: performReloc {s}", .{@tagName(ops)}),
        },
        else => std.debug.panic("TODO: performReloc {s}", .{@tagName(tag)}),
    }
}

fn airBr(func: *Func, inst: Air.Inst.Index) !void {
    const mod = func.bin_file.comp.module.?;
    const br = func.air.instructions.items(.data)[@intFromEnum(inst)].br;

    const block_ty = func.typeOfIndex(br.block_inst);
    const block_unused =
        !block_ty.hasRuntimeBitsIgnoreComptime(mod) or func.liveness.isUnused(br.block_inst);
    const block_tracking = func.inst_tracking.getPtr(br.block_inst).?;
    const block_data = func.blocks.getPtr(br.block_inst).?;
    const first_br = block_data.relocs.items.len == 0;
    const block_result = result: {
        if (block_unused) break :result .none;

        if (!first_br) try func.getValue(block_tracking.short, null);
        const src_mcv = try func.resolveInst(br.operand);

        if (func.reuseOperandAdvanced(inst, br.operand, 0, src_mcv, br.block_inst)) {
            if (first_br) break :result src_mcv;

            try func.getValue(block_tracking.short, br.block_inst);
            // .long = .none to avoid merging operand and block result stack frames.
            const current_tracking: InstTracking = .{ .long = .none, .short = src_mcv };
            try current_tracking.materializeUnsafe(func, br.block_inst, block_tracking.*);
            for (current_tracking.getRegs()) |src_reg| func.register_manager.freeReg(src_reg);
            break :result block_tracking.short;
        }

        const dst_mcv = if (first_br) try func.allocRegOrMem(block_ty, br.block_inst, true) else dst: {
            try func.getValue(block_tracking.short, br.block_inst);
            break :dst block_tracking.short;
        };
        try func.genCopy(block_ty, dst_mcv, try func.resolveInst(br.operand));
        break :result dst_mcv;
    };

    // Process operand death so that it is properly accounted for in the State below.
    if (func.liveness.operandDies(inst, 0)) {
        if (br.operand.toIndex()) |op_inst| try func.processDeath(op_inst);
    }

    if (first_br) {
        block_tracking.* = InstTracking.init(block_result);
        try func.saveRetroactiveState(&block_data.state);
    } else try func.restoreState(block_data.state, &.{}, .{
        .emit_instructions = true,
        .update_tracking = false,
        .resurrect = false,
        .close_scope = false,
    });

    // Emit a jump with a relocation. It will be patched up after the block ends.
    // Leave the jump offset undefined
    const jmp_reloc = try func.jump(undefined);
    try block_data.relocs.append(func.gpa, jmp_reloc);

    // Stop tracking block result without forgetting tracking info
    try func.freeValue(block_tracking.short);

    func.finishAirBookkeeping();
}

fn airBoolOp(func: *Func, inst: Air.Inst.Index) !void {
    const bin_op = func.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
    const tag: Air.Inst.Tag = func.air.instructions.items(.tag)[@intFromEnum(inst)];

    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else result: {
        const lhs = try func.resolveInst(bin_op.lhs);
        const rhs = try func.resolveInst(bin_op.rhs);
        const lhs_ty = Type.bool;
        const rhs_ty = Type.bool;

        const lhs_reg, const lhs_lock = try func.promoteReg(lhs_ty, lhs);
        defer if (lhs_lock) |lock| func.register_manager.unlockReg(lock);

        const rhs_reg, const rhs_lock = try func.promoteReg(rhs_ty, rhs);
        defer if (rhs_lock) |lock| func.register_manager.unlockReg(lock);

        const result_reg, const result_lock = try func.allocReg(.int);
        defer func.register_manager.unlockReg(result_lock);

        _ = try func.addInst(.{
            .tag = if (tag == .bool_or) .@"or" else .@"and",
            .ops = .rrr,
            .data = .{ .r_type = .{
                .rd = result_reg,
                .rs1 = lhs_reg,
                .rs2 = rhs_reg,
            } },
        });

        // safety truncate
        if (func.wantSafety()) {
            _ = try func.addInst(.{
                .tag = .andi,
                .ops = .rri,
                .data = .{ .i_type = .{
                    .rd = result_reg,
                    .rs1 = result_reg,
                    .imm12 = Immediate.s(1),
                } },
            });
        }

        break :result .{ .register = result_reg };
    };
    return func.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airAsm(func: *Func, inst: Air.Inst.Index) !void {
    const ty_pl = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const extra = func.air.extraData(Air.Asm, ty_pl.payload);
    const is_volatile = @as(u1, @truncate(extra.data.flags >> 31)) != 0;
    const clobbers_len: u31 = @truncate(extra.data.flags);
    var extra_i: usize = extra.end;
    const outputs: []const Air.Inst.Ref =
        @ptrCast(func.air.extra[extra_i..][0..extra.data.outputs_len]);
    extra_i += outputs.len;
    const inputs: []const Air.Inst.Ref = @ptrCast(func.air.extra[extra_i..][0..extra.data.inputs_len]);
    extra_i += inputs.len;

    log.debug("airAsm input: {any}", .{inputs});

    const dead = !is_volatile and func.liveness.isUnused(inst);
    const result: MCValue = if (dead) .unreach else result: {
        if (outputs.len > 1) {
            return func.fail("TODO implement codegen for asm with more than 1 output", .{});
        }

        const output_constraint: ?[]const u8 = for (outputs) |output| {
            if (output != .none) {
                return func.fail("TODO implement codegen for non-expr asm", .{});
            }
            const extra_bytes = std.mem.sliceAsBytes(func.air.extra[extra_i..]);
            const constraint = std.mem.sliceTo(std.mem.sliceAsBytes(func.air.extra[extra_i..]), 0);
            const name = std.mem.sliceTo(extra_bytes[constraint.len + 1 ..], 0);
            // This equation accounts for the fact that even if we have exactly 4 bytes
            // for the string, we still use the next u32 for the null terminator.
            extra_i += (constraint.len + name.len + (2 + 3)) / 4;

            break constraint;
        } else null;

        for (inputs) |input| {
            const input_bytes = std.mem.sliceAsBytes(func.air.extra[extra_i..]);
            const constraint = std.mem.sliceTo(input_bytes, 0);
            const name = std.mem.sliceTo(input_bytes[constraint.len + 1 ..], 0);
            // This equation accounts for the fact that even if we have exactly 4 bytes
            // for the string, we still use the next u32 for the null terminator.
            extra_i += (constraint.len + name.len + (2 + 3)) / 4;

            if (constraint.len < 3 or constraint[0] != '{' or constraint[constraint.len - 1] != '}') {
                return func.fail("unrecognized asm input constraint: '{s}'", .{constraint});
            }
            const reg_name = constraint[1 .. constraint.len - 1];
            const reg = parseRegName(reg_name) orelse
                return func.fail("unrecognized register: '{s}'", .{reg_name});

            const arg_mcv = try func.resolveInst(input);
            try func.register_manager.getReg(reg, null);
            try func.genSetReg(func.typeOf(input), reg, arg_mcv);
        }

        {
            var clobber_i: u32 = 0;
            while (clobber_i < clobbers_len) : (clobber_i += 1) {
                const clobber = std.mem.sliceTo(std.mem.sliceAsBytes(func.air.extra[extra_i..]), 0);
                // This equation accounts for the fact that even if we have exactly 4 bytes
                // for the string, we still use the next u32 for the null terminator.
                extra_i += clobber.len / 4 + 1;

                if (std.mem.eql(u8, clobber, "") or std.mem.eql(u8, clobber, "memory")) {
                    // nothing really to do
                } else {
                    try func.register_manager.getReg(parseRegName(clobber) orelse
                        return func.fail("invalid clobber: '{s}'", .{clobber}), null);
                }
            }
        }

        const asm_source = std.mem.sliceAsBytes(func.air.extra[extra_i..])[0..extra.data.source_len];

        if (std.meta.stringToEnum(Mir.Inst.Tag, asm_source)) |tag| {
            _ = try func.addInst(.{
                .tag = tag,
                .ops = .none,
                .data = undefined,
            });
        } else {
            return func.fail("TODO: asm_source {s}", .{asm_source});
        }

        if (output_constraint) |output| {
            if (output.len < 4 or output[0] != '=' or output[1] != '{' or output[output.len - 1] != '}') {
                return func.fail("unrecognized asm output constraint: '{s}'", .{output});
            }
            const reg_name = output[2 .. output.len - 1];
            const reg = parseRegName(reg_name) orelse
                return func.fail("unrecognized register: '{s}'", .{reg_name});
            break :result .{ .register = reg };
        } else {
            break :result .{ .none = {} };
        }
    };

    simple: {
        var buf = [1]Air.Inst.Ref{.none} ** (Liveness.bpi - 1);
        var buf_index: usize = 0;
        for (outputs) |output| {
            if (output == .none) continue;

            if (buf_index >= buf.len) break :simple;
            buf[buf_index] = output;
            buf_index += 1;
        }
        if (buf_index + inputs.len > buf.len) break :simple;
        @memcpy(buf[buf_index..][0..inputs.len], inputs);
        return func.finishAir(inst, result, buf);
    }
    var bt = func.liveness.iterateBigTomb(inst);
    for (outputs) |output| if (output != .none) try func.feed(&bt, output);
    for (inputs) |input| try func.feed(&bt, input);
    return func.finishAirResult(inst, result);
}

/// Sets the value of `dst_mcv` to the value of `src_mcv`.
fn genCopy(func: *Func, ty: Type, dst_mcv: MCValue, src_mcv: MCValue) !void {
    const zcu = func.bin_file.comp.module.?;

    // There isn't anything to store
    if (dst_mcv == .none) return;

    if (!dst_mcv.isMutable()) {
        // panic so we can see the trace
        return std.debug.panic("tried to genCopy immutable: {s}", .{@tagName(dst_mcv)});
    }

    switch (dst_mcv) {
        .register => |reg| return func.genSetReg(ty, reg, src_mcv),
        .register_offset => |dst_reg_off| try func.genSetReg(ty, dst_reg_off.reg, switch (src_mcv) {
            .none,
            .unreach,
            .dead,
            .undef,
            => unreachable,
            .immediate,
            .register,
            .register_offset,
            => src_mcv.offset(-dst_reg_off.off),
            else => .{ .register_offset = .{
                .reg = try func.copyToTmpRegister(ty, src_mcv),
                .off = -dst_reg_off.off,
            } },
        }),
        .indirect => |reg_off| try func.genSetMem(
            .{ .reg = reg_off.reg },
            reg_off.off,
            ty,
            src_mcv,
        ),
        .load_frame => |frame_addr| try func.genSetMem(
            .{ .frame = frame_addr.index },
            frame_addr.off,
            ty,
            src_mcv,
        ),
        .memory => return func.fail("TODO: genCopy memory", .{}),
        .register_pair => |dst_regs| {
            const src_info: ?struct { addr_reg: Register, addr_lock: ?RegisterLock } = switch (src_mcv) {
                .register_pair, .memory, .indirect, .load_frame => null,
                .load_symbol => src: {
                    const src_addr_reg, const src_addr_lock = try func.promoteReg(Type.usize, src_mcv.address());
                    errdefer func.register_manager.unlockReg(src_addr_lock);

                    break :src .{ .addr_reg = src_addr_reg, .addr_lock = src_addr_lock };
                },
                .air_ref => |src_ref| return func.genCopy(
                    ty,
                    dst_mcv,
                    try func.resolveInst(src_ref),
                ),
                else => return func.fail("genCopy register_pair src: {}", .{src_mcv}),
            };

            defer if (src_info) |info| {
                if (info.addr_lock) |lock| {
                    func.register_manager.unlockReg(lock);
                }
            };

            var part_disp: i32 = 0;
            for (dst_regs, try func.splitType(ty), 0..) |dst_reg, dst_ty, part_i| {
                try func.genSetReg(dst_ty, dst_reg, switch (src_mcv) {
                    .register_pair => |src_regs| .{ .register = src_regs[part_i] },
                    .memory, .indirect, .load_frame => src_mcv.address().offset(part_disp).deref(),
                    .load_symbol => .{ .indirect = .{
                        .reg = src_info.?.addr_reg,
                        .off = part_disp,
                    } },
                    else => unreachable,
                });
                part_disp += @intCast(dst_ty.abiSize(zcu));
            }
        },
        else => return func.fail("TODO: genCopy to {s} from {s}", .{ @tagName(dst_mcv), @tagName(src_mcv) }),
    }
}

fn genInlineMemcpy(
    func: *Func,
    dst_ptr: MCValue,
    src_ptr: MCValue,
    len: MCValue,
) !void {
    const regs = try func.register_manager.allocRegs(4, .{null} ** 4, abi.Registers.Integer.temporary);
    const locks = func.register_manager.lockRegsAssumeUnused(4, regs);
    defer for (locks) |lock| func.register_manager.unlockReg(lock);

    const count = regs[0];
    const tmp = regs[1];
    const src = regs[2];
    const dst = regs[3];

    try func.genSetReg(Type.usize, count, len);
    try func.genSetReg(Type.usize, src, src_ptr);
    try func.genSetReg(Type.usize, dst, dst_ptr);

    // lb tmp, 0(src)
    const first_inst = try func.addInst(.{
        .tag = .lb,
        .ops = .rri,
        .data = .{
            .i_type = .{
                .rd = tmp,
                .rs1 = src,
                .imm12 = Immediate.s(0),
            },
        },
    });

    // sb tmp, 0(dst)
    _ = try func.addInst(.{
        .tag = .sb,
        .ops = .rri,
        .data = .{
            .i_type = .{
                .rd = dst,
                .rs1 = tmp,
                .imm12 = Immediate.s(0),
            },
        },
    });

    // dec count by 1
    _ = try func.addInst(.{
        .tag = .addi,
        .ops = .rri,
        .data = .{
            .i_type = .{
                .rd = count,
                .rs1 = count,
                .imm12 = Immediate.s(-1),
            },
        },
    });

    // branch if count is 0
    _ = try func.addInst(.{
        .tag = .beq,
        .ops = .rr_inst,
        .data = .{
            .b_type = .{
                .inst = @intCast(func.mir_instructions.len + 4), // points after the last inst
                .rs1 = count,
                .rs2 = .zero,
            },
        },
    });

    // increment the pointers
    _ = try func.addInst(.{
        .tag = .addi,
        .ops = .rri,
        .data = .{
            .i_type = .{
                .rd = src,
                .rs1 = src,
                .imm12 = Immediate.s(1),
            },
        },
    });

    _ = try func.addInst(.{
        .tag = .addi,
        .ops = .rri,
        .data = .{
            .i_type = .{
                .rd = dst,
                .rs1 = dst,
                .imm12 = Immediate.s(1),
            },
        },
    });

    // jump back to start of loop
    _ = try func.addInst(.{
        .tag = .pseudo,
        .ops = .pseudo_j,
        .data = .{ .inst = first_inst },
    });
}

fn genInlineMemset(
    func: *Func,
    dst_ptr: MCValue,
    src_value: MCValue,
    len: MCValue,
) !void {
    const regs = try func.register_manager.allocRegs(3, .{null} ** 3, abi.Registers.Integer.temporary);
    const locks = func.register_manager.lockRegsAssumeUnused(3, regs);
    defer for (locks) |lock| func.register_manager.unlockReg(lock);

    const count = regs[0];
    const src = regs[1];
    const dst = regs[2];

    try func.genSetReg(Type.usize, count, len);
    try func.genSetReg(Type.usize, src, src_value);
    try func.genSetReg(Type.usize, dst, dst_ptr);

    // sb src, 0(dst)
    const first_inst = try func.addInst(.{
        .tag = .sb,
        .ops = .rri,
        .data = .{
            .i_type = .{
                .rd = dst,
                .rs1 = src,
                .imm12 = Immediate.s(0),
            },
        },
    });

    // dec count by 1
    _ = try func.addInst(.{
        .tag = .addi,
        .ops = .rri,
        .data = .{
            .i_type = .{
                .rd = count,
                .rs1 = count,
                .imm12 = Immediate.s(-1),
            },
        },
    });

    // branch if count is 0
    _ = try func.addInst(.{
        .tag = .beq,
        .ops = .rr_inst,
        .data = .{
            .b_type = .{
                .inst = @intCast(func.mir_instructions.len + 4), // points after the last inst
                .rs1 = count,
                .rs2 = .zero,
            },
        },
    });

    // increment the pointers
    _ = try func.addInst(.{
        .tag = .addi,
        .ops = .rri,
        .data = .{
            .i_type = .{
                .rd = dst,
                .rs1 = dst,
                .imm12 = Immediate.s(1),
            },
        },
    });

    // jump back to start of loop
    _ = try func.addInst(.{
        .tag = .pseudo,
        .ops = .pseudo_j,
        .data = .{
            .inst = first_inst,
        },
    });
}

/// Sets the value of `src_mcv` into `reg`. Assumes you have a lock on it.
fn genSetReg(func: *Func, ty: Type, reg: Register, src_mcv: MCValue) InnerError!void {
    const zcu = func.bin_file.comp.module.?;
    const abi_size: u32 = @intCast(ty.abiSize(zcu));

    if (abi_size > 8) return std.debug.panic("tried to set reg with size {}", .{abi_size});

    const dst_reg_class = reg.class();

    switch (src_mcv) {
        .dead => unreachable,
        .unreach, .none => return, // Nothing to do.
        .undef => {
            if (!func.wantSafety())
                return; // The already existing value will do just fine.
            // Write the debug undefined value.
            return func.genSetReg(ty, reg, .{ .immediate = 0xaaaaaaaaaaaaaaaa });
        },
        .immediate => |unsigned_x| {
            assert(dst_reg_class == .int);

            const x: i64 = @bitCast(unsigned_x);
            if (math.minInt(i12) <= x and x <= math.maxInt(i12)) {
                _ = try func.addInst(.{
                    .tag = .addi,
                    .ops = .rri,
                    .data = .{ .i_type = .{
                        .rd = reg,
                        .rs1 = .zero,
                        .imm12 = Immediate.s(@intCast(x)),
                    } },
                });
            } else if (math.minInt(i32) <= x and x <= math.maxInt(i32)) {
                const lo12: i12 = @truncate(x);
                const carry: i32 = if (lo12 < 0) 1 else 0;
                const hi20: i20 = @truncate((x >> 12) +% carry);

                _ = try func.addInst(.{
                    .tag = .lui,
                    .ops = .ri,
                    .data = .{ .u_type = .{
                        .rd = reg,
                        .imm20 = Immediate.s(hi20),
                    } },
                });
                _ = try func.addInst(.{
                    .tag = .addi,
                    .ops = .rri,
                    .data = .{ .i_type = .{
                        .rd = reg,
                        .rs1 = reg,
                        .imm12 = Immediate.s(lo12),
                    } },
                });
            } else {
                // TODO: use a more advanced myriad seq to do this without a reg.
                // see: https://github.com/llvm/llvm-project/blob/081a66ffacfe85a37ff775addafcf3371e967328/llvm/lib/Target/RISCV/MCTargetDesc/RISCVMatInt.cpp#L224

                const temp, const temp_lock = try func.allocReg(.int);
                defer func.register_manager.unlockReg(temp_lock);

                const lo32: i32 = @truncate(x);
                const carry: i32 = if (lo32 < 0) 1 else 0;
                const hi32: i32 = @truncate((x >> 32) +% carry);

                try func.genSetReg(Type.i32, temp, .{ .immediate = @bitCast(@as(i64, lo32)) });
                try func.genSetReg(Type.i32, reg, .{ .immediate = @bitCast(@as(i64, hi32)) });

                _ = try func.addInst(.{
                    .tag = .slli,
                    .ops = .rri,
                    .data = .{ .i_type = .{
                        .rd = reg,
                        .rs1 = reg,
                        .imm12 = Immediate.u(32),
                    } },
                });

                _ = try func.addInst(.{
                    .tag = .add,
                    .ops = .rrr,
                    .data = .{ .r_type = .{
                        .rd = reg,
                        .rs1 = reg,
                        .rs2 = temp,
                    } },
                });
            }
        },
        .register => |src_reg| {
            // If the registers are the same, nothing to do.
            if (src_reg.id() == reg.id())
                return;

            const src_reg_class = src_reg.class();

            if (src_reg_class == .float and dst_reg_class == .int) {
                // to move from float -> int, we use FMV.X.W
                return func.fail("TODO: genSetReg float -> int", .{});
            }

            // mv reg, src_reg
            _ = try func.addInst(.{
                .tag = .pseudo,
                .ops = .pseudo_mv,
                .data = .{ .rr = .{
                    .rd = reg,
                    .rs = src_reg,
                } },
            });
        },
        .register_pair => return func.fail("genSetReg should we allow reg -> reg_pair?", .{}),
        .load_frame => |frame| {
            _ = try func.addInst(.{
                .tag = .pseudo,
                .ops = .pseudo_load_rm,
                .data = .{ .rm = .{
                    .r = reg,
                    .m = .{
                        .base = .{ .frame = frame.index },
                        .mod = .{
                            .size = func.memSize(ty),
                            .unsigned = ty.isUnsignedInt(zcu),
                            .disp = frame.off,
                        },
                    },
                } },
            });
        },
        .memory => |addr| {
            try func.genSetReg(ty, reg, .{ .immediate = addr });

            _ = try func.addInst(.{
                .tag = .ld,
                .ops = .rri,
                .data = .{ .i_type = .{
                    .rd = reg,
                    .rs1 = reg,
                    .imm12 = Immediate.u(0),
                } },
            });
        },
        .lea_frame, .register_offset => {
            _ = try func.addInst(.{
                .tag = .pseudo,
                .ops = .pseudo_lea_rm,
                .data = .{ .rm = .{
                    .r = reg,
                    .m = switch (src_mcv) {
                        .register_offset => |reg_off| .{
                            .base = .{ .reg = reg_off.reg },
                            .mod = .{
                                .size = func.memSize(ty),
                                .disp = reg_off.off,
                                .unsigned = false,
                            },
                        },
                        .lea_frame => |frame| .{
                            .base = .{ .frame = frame.index },
                            .mod = .{
                                .size = func.memSize(ty),
                                .disp = frame.off,
                                .unsigned = false,
                            },
                        },
                        else => unreachable,
                    },
                } },
            });
        },
        .indirect => |reg_off| {
            const float_class = dst_reg_class == .float;

            const load_tag: Mir.Inst.Tag = switch (abi_size) {
                1 => if (float_class)
                    unreachable // Zig does not support 8-bit floats
                else
                    .lb,
                2 => if (float_class)
                    return func.fail("TODO: genSetReg indirect 16-bit float", .{})
                else
                    .lh,
                4 => if (float_class) .flw else .lw,
                8 => if (float_class) .fld else .ld,
                else => return std.debug.panic("TODO: genSetReg for size {d}", .{abi_size}),
            };

            _ = try func.addInst(.{
                .tag = load_tag,
                .ops = .rri,
                .data = .{ .i_type = .{
                    .rd = reg,
                    .rs1 = reg_off.reg,
                    .imm12 = Immediate.s(reg_off.off),
                } },
            });
        },
        .lea_symbol => |sym_off| {
            assert(sym_off.off == 0);

            const atom_index = try func.symbolIndex();

            _ = try func.addInst(.{
                .tag = .pseudo,
                .ops = .pseudo_load_symbol,
                .data = .{ .payload = try func.addExtra(Mir.LoadSymbolPayload{
                    .register = reg.encodeId(),
                    .atom_index = atom_index,
                    .sym_index = sym_off.sym,
                }) },
            });
        },
        .load_symbol => {
            const addr_reg, const addr_lock = try func.allocReg(.int);
            defer func.register_manager.unlockReg(addr_lock);

            try func.genSetReg(ty, addr_reg, src_mcv.address());
            try func.genSetReg(ty, reg, .{ .indirect = .{ .reg = addr_reg } });
        },
        .air_ref => |ref| try func.genSetReg(ty, reg, try func.resolveInst(ref)),
        else => return func.fail("TODO: genSetReg {s}", .{@tagName(src_mcv)}),
    }
}

fn genSetMem(
    func: *Func,
    base: Memory.Base,
    disp: i32,
    ty: Type,
    src_mcv: MCValue,
) InnerError!void {
    const mod = func.bin_file.comp.module.?;
    const abi_size: u32 = @intCast(ty.abiSize(mod));
    const dst_ptr_mcv: MCValue = switch (base) {
        .reg => |base_reg| .{ .register_offset = .{ .reg = base_reg, .off = disp } },
        .frame => |base_frame_index| .{ .lea_frame = .{ .index = base_frame_index, .off = disp } },
        .reloc => |base_symbol| .{ .lea_symbol = .{ .sym = base_symbol.sym_index, .off = disp } },
    };
    switch (src_mcv) {
        .none,
        .unreach,
        .dead,
        .reserved_frame,
        => unreachable,
        .undef => try func.genInlineMemset(
            dst_ptr_mcv,
            src_mcv,
            .{ .immediate = abi_size },
        ),
        .register_offset,
        .memory,
        .indirect,
        .load_frame,
        .lea_frame,
        .load_symbol,
        .lea_symbol,
        => switch (abi_size) {
            0 => {},
            1, 2, 4, 8 => {
                // no matter what type, it should use an integer register
                const src_reg = try func.copyToTmpRegister(Type.usize, src_mcv);
                const src_lock = func.register_manager.lockRegAssumeUnused(src_reg);
                defer func.register_manager.unlockReg(src_lock);

                try func.genSetMem(base, disp, ty, .{ .register = src_reg });
            },
            else => try func.genInlineMemcpy(
                dst_ptr_mcv,
                src_mcv.address(),
                .{ .immediate = abi_size },
            ),
        },
        .register => |reg| {
            const mem_size = switch (base) {
                .frame => |base_fi| mem_size: {
                    assert(disp >= 0);
                    const frame_abi_size = func.frame_allocs.items(.abi_size)[@intFromEnum(base_fi)];
                    const frame_spill_pad = func.frame_allocs.items(.spill_pad)[@intFromEnum(base_fi)];
                    assert(frame_abi_size - frame_spill_pad - disp >= abi_size);
                    break :mem_size if (frame_abi_size - frame_spill_pad - disp == abi_size)
                        frame_abi_size
                    else
                        abi_size;
                },
                else => abi_size,
            };
            const src_size = math.ceilPowerOfTwoAssert(u32, abi_size);
            const src_align = Alignment.fromNonzeroByteUnits(math.ceilPowerOfTwoAssert(u32, src_size));
            if (src_size > mem_size) {
                const frame_index = try func.allocFrameIndex(FrameAlloc.init(.{
                    .size = src_size,
                    .alignment = src_align,
                }));
                const frame_mcv: MCValue = .{ .load_frame = .{ .index = frame_index } };
                _ = try func.addInst(.{
                    .tag = .pseudo,
                    .ops = .pseudo_store_rm,
                    .data = .{ .rm = .{
                        .r = reg,
                        .m = .{
                            .base = .{ .frame = frame_index },
                            .mod = .{
                                .size = Memory.Size.fromByteSize(src_size),
                                .unsigned = false,
                            },
                        },
                    } },
                });
                try func.genSetMem(base, disp, ty, frame_mcv);
                try func.freeValue(frame_mcv);
            } else _ = try func.addInst(.{
                .tag = .pseudo,
                .ops = .pseudo_store_rm,
                .data = .{ .rm = .{
                    .r = reg,
                    .m = .{
                        .base = base,
                        .mod = .{
                            .size = func.memSize(ty),
                            .disp = disp,
                            .unsigned = false,
                        },
                    },
                } },
            });
        },
        .register_pair => |src_regs| {
            var part_disp: i32 = disp;
            for (try func.splitType(ty), src_regs) |src_ty, src_reg| {
                try func.genSetMem(base, part_disp, src_ty, .{ .register = src_reg });
                part_disp += @intCast(src_ty.abiSize(mod));
            }
        },
        .immediate => {
            // TODO: remove this lock in favor of a copyToTmpRegister when we load 64 bit immediates with
            // a register allocation.
            const reg, const reg_lock = try func.promoteReg(ty, src_mcv);
            defer if (reg_lock) |lock| func.register_manager.unlockReg(lock);

            return func.genSetMem(base, disp, ty, .{ .register = reg });
        },
        .air_ref => |src_ref| try func.genSetMem(base, disp, ty, try func.resolveInst(src_ref)),
    }
}

fn airIntFromPtr(func: *Func, inst: Air.Inst.Index) !void {
    const un_op = func.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const result = result: {
        const src_mcv = try func.resolveInst(un_op);
        const src_ty = func.typeOfIndex(inst);
        if (func.reuseOperand(inst, un_op, 0, src_mcv)) break :result src_mcv;

        const dst_mcv = try func.allocRegOrMem(src_ty, inst, true);
        const dst_ty = func.typeOfIndex(inst);
        try func.genCopy(dst_ty, dst_mcv, src_mcv);
        break :result dst_mcv;
    };
    return func.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airBitCast(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;

    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result = if (func.liveness.isUnused(inst)) .unreach else result: {
        const src_mcv = try func.resolveInst(ty_op.operand);

        const dst_ty = func.typeOfIndex(inst);
        const src_ty = func.typeOf(ty_op.operand);

        const src_lock = if (src_mcv.getReg()) |reg| func.register_manager.lockReg(reg) else null;
        defer if (src_lock) |lock| func.register_manager.unlockReg(lock);

        const dst_mcv = if (dst_ty.abiSize(zcu) <= src_ty.abiSize(zcu) and
            func.reuseOperand(inst, ty_op.operand, 0, src_mcv)) src_mcv else dst: {
            const dst_mcv = try func.allocRegOrMem(dst_ty, inst, true);
            try func.genCopy(switch (math.order(dst_ty.abiSize(zcu), src_ty.abiSize(zcu))) {
                .lt => dst_ty,
                .eq => if (!dst_mcv.isMemory() or src_mcv.isMemory()) dst_ty else src_ty,
                .gt => src_ty,
            }, dst_mcv, src_mcv);
            break :dst dst_mcv;
        };

        if (dst_ty.isAbiInt(zcu) and src_ty.isAbiInt(zcu) and
            dst_ty.intInfo(zcu).signedness == src_ty.intInfo(zcu).signedness) break :result dst_mcv;

        const abi_size = dst_ty.abiSize(zcu);
        const bit_size = dst_ty.bitSize(zcu);
        if (abi_size * 8 <= bit_size) break :result dst_mcv;

        return func.fail("TODO: airBitCast {} to {}", .{ src_ty.fmt(zcu), dst_ty.fmt(zcu) });
    };
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airArrayToSlice(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;

    const slice_ty = func.typeOfIndex(inst);
    const ptr_ty = func.typeOf(ty_op.operand);
    const ptr = try func.resolveInst(ty_op.operand);
    const array_ty = ptr_ty.childType(zcu);
    const array_len = array_ty.arrayLen(zcu);

    const frame_index = try func.allocFrameIndex(FrameAlloc.initSpill(slice_ty, zcu));
    try func.genSetMem(.{ .frame = frame_index }, 0, ptr_ty, ptr);
    try func.genSetMem(
        .{ .frame = frame_index },
        @intCast(ptr_ty.abiSize(zcu)),
        Type.usize,
        .{ .immediate = array_len },
    );

    const result = MCValue{ .load_frame = .{ .index = frame_index } };
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airFloatFromInt(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airFloatFromInt for {}", .{
        func.target.cpu.arch,
    });
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airIntFromFloat(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airIntFromFloat for {}", .{
        func.target.cpu.arch,
    });
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airCmpxchg(func: *Func, inst: Air.Inst.Index) !void {
    const ty_pl = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const extra = func.air.extraData(Air.Block, ty_pl.payload);
    _ = extra;
    return func.fail("TODO implement airCmpxchg for {}", .{
        func.target.cpu.arch,
    });
    // return func.finishAir(inst, result, .{ extra.ptr, extra.expected_value, extra.new_value });
}

fn airAtomicRmw(func: *Func, inst: Air.Inst.Index) !void {
    _ = inst;
    return func.fail("TODO implement airCmpxchg for {}", .{func.target.cpu.arch});
}

fn airAtomicLoad(func: *Func, inst: Air.Inst.Index) !void {
    _ = inst;
    return func.fail("TODO implement airAtomicLoad for {}", .{func.target.cpu.arch});
}

fn airAtomicStore(func: *Func, inst: Air.Inst.Index, order: std.builtin.AtomicOrder) !void {
    _ = inst;
    _ = order;
    return func.fail("TODO implement airAtomicStore for {}", .{func.target.cpu.arch});
}

fn airMemset(func: *Func, inst: Air.Inst.Index, safety: bool) !void {
    const zcu = func.bin_file.comp.module.?;
    const bin_op = func.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

    result: {
        if (!safety and (try func.resolveInst(bin_op.rhs)) == .undef) break :result;

        const dst_ptr = try func.resolveInst(bin_op.lhs);
        const dst_ptr_ty = func.typeOf(bin_op.lhs);
        const dst_ptr_lock: ?RegisterLock = switch (dst_ptr) {
            .register => |reg| func.register_manager.lockRegAssumeUnused(reg),
            else => null,
        };
        defer if (dst_ptr_lock) |lock| func.register_manager.unlockReg(lock);

        const src_val = try func.resolveInst(bin_op.rhs);
        const elem_ty = func.typeOf(bin_op.rhs);
        const src_val_lock: ?RegisterLock = switch (src_val) {
            .register => |reg| func.register_manager.lockRegAssumeUnused(reg),
            else => null,
        };
        defer if (src_val_lock) |lock| func.register_manager.unlockReg(lock);

        const elem_abi_size: u31 = @intCast(elem_ty.abiSize(zcu));

        if (elem_abi_size == 1) {
            const ptr: MCValue = switch (dst_ptr_ty.ptrSize(zcu)) {
                // TODO: this only handles slices stored in the stack
                .Slice => dst_ptr,
                .One => dst_ptr,
                .C, .Many => unreachable,
            };
            const len: MCValue = switch (dst_ptr_ty.ptrSize(zcu)) {
                // TODO: this only handles slices stored in the stack
                .Slice => dst_ptr.address().offset(8).deref(),
                .One => .{ .immediate = dst_ptr_ty.childType(zcu).arrayLen(zcu) },
                .C, .Many => unreachable,
            };
            const len_lock: ?RegisterLock = switch (len) {
                .register => |reg| func.register_manager.lockRegAssumeUnused(reg),
                else => null,
            };
            defer if (len_lock) |lock| func.register_manager.unlockReg(lock);

            try func.genInlineMemset(ptr, src_val, len);
            break :result;
        }

        // Store the first element, and then rely on memcpy copying forwards.
        // Length zero requires a runtime check - so we handle arrays specially
        // here to elide it.
        switch (dst_ptr_ty.ptrSize(zcu)) {
            .Slice => return func.fail("TODO: airMemset Slices", .{}),
            .One => {
                const elem_ptr_ty = try zcu.singleMutPtrType(elem_ty);

                const len = dst_ptr_ty.childType(zcu).arrayLen(zcu);

                assert(len != 0); // prevented by Sema
                try func.store(dst_ptr, src_val, elem_ptr_ty, elem_ty);

                const second_elem_ptr_reg, const second_elem_ptr_lock = try func.allocReg(.int);
                defer func.register_manager.unlockReg(second_elem_ptr_lock);

                const second_elem_ptr_mcv: MCValue = .{ .register = second_elem_ptr_reg };

                try func.genSetReg(Type.usize, second_elem_ptr_reg, .{ .register_offset = .{
                    .reg = try func.copyToTmpRegister(Type.usize, dst_ptr),
                    .off = elem_abi_size,
                } });

                const bytes_to_copy: MCValue = .{ .immediate = elem_abi_size * (len - 1) };
                try func.genInlineMemcpy(second_elem_ptr_mcv, dst_ptr, bytes_to_copy);
            },
            .C, .Many => unreachable,
        }
    }
    return func.finishAir(inst, .unreach, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airMemcpy(func: *Func, inst: Air.Inst.Index) !void {
    _ = inst;
    return func.fail("TODO implement airMemcpy for {}", .{func.target.cpu.arch});
}

fn airTagName(func: *Func, inst: Air.Inst.Index) !void {
    const un_op = func.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const operand = try func.resolveInst(un_op);
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else {
        _ = operand;
        return func.fail("TODO implement airTagName for riscv64", .{});
    };
    return func.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airErrorName(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const un_op = func.air.instructions.items(.data)[@intFromEnum(inst)].un_op;

    const err_ty = func.typeOf(un_op);
    const err_mcv = try func.resolveInst(un_op);

    const err_reg = try func.copyToTmpRegister(err_ty, err_mcv);
    const err_lock = func.register_manager.lockRegAssumeUnused(err_reg);
    defer func.register_manager.unlockReg(err_lock);

    const addr_reg, const addr_lock = try func.allocReg(.int);
    defer func.register_manager.unlockReg(addr_lock);

    // this is now the base address of the error name table
    const lazy_sym = link.File.LazySymbol.initDecl(.const_data, null, zcu);
    if (func.bin_file.cast(link.File.Elf)) |elf_file| {
        const sym_index = elf_file.zigObjectPtr().?.getOrCreateMetadataForLazySymbol(elf_file, lazy_sym) catch |err|
            return func.fail("{s} creating lazy symbol", .{@errorName(err)});
        const sym = elf_file.symbol(sym_index);
        try func.genSetReg(Type.usize, addr_reg, .{ .load_symbol = .{ .sym = sym.esym_index } });
    } else {
        return func.fail("TODO: riscv non-elf", .{});
    }

    const start_reg, const start_lock = try func.allocReg(.int);
    defer func.register_manager.unlockReg(start_lock);

    const end_reg, const end_lock = try func.allocReg(.int);
    defer func.register_manager.unlockReg(end_lock);

    // const tmp_reg, const tmp_lock = try func.allocReg(.int);
    // defer func.register_manager.unlockReg(tmp_lock);

    // we move the base address forward by the following formula: base + (errno * 8)

    // shifting left by 4 is the same as multiplying by 8
    _ = try func.addInst(.{
        .tag = .slli,
        .ops = .rri,
        .data = .{ .i_type = .{
            .imm12 = Immediate.u(4),
            .rd = err_reg,
            .rs1 = err_reg,
        } },
    });

    _ = try func.addInst(.{
        .tag = .add,
        .ops = .rrr,
        .data = .{ .r_type = .{
            .rd = addr_reg,
            .rs1 = addr_reg,
            .rs2 = err_reg,
        } },
    });

    _ = try func.addInst(.{
        .tag = .pseudo,
        .ops = .pseudo_load_rm,
        .data = .{
            .rm = .{
                .r = start_reg,
                .m = .{
                    .base = .{ .reg = addr_reg },
                    .mod = .{ .size = .dword, .unsigned = true },
                },
            },
        },
    });

    _ = try func.addInst(.{
        .tag = .pseudo,
        .ops = .pseudo_load_rm,
        .data = .{
            .rm = .{
                .r = end_reg,
                .m = .{
                    .base = .{ .reg = addr_reg },
                    .mod = .{ .size = .dword, .unsigned = true },
                },
            },
        },
    });

    const dst_mcv = try func.allocRegOrMem(func.typeOfIndex(inst), inst, false);
    const frame = dst_mcv.load_frame;
    try func.genSetMem(
        .{ .frame = frame.index },
        frame.off,
        Type.usize,
        .{ .register = start_reg },
    );

    try func.genSetMem(
        .{ .frame = frame.index },
        frame.off + 8,
        Type.usize,
        .{ .register = end_reg },
    );

    return func.finishAir(inst, dst_mcv, .{ un_op, .none, .none });
}

fn airSplat(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airSplat for riscv64", .{});
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airSelect(func: *Func, inst: Air.Inst.Index) !void {
    const pl_op = func.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
    const extra = func.air.extraData(Air.Bin, pl_op.payload).data;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airSelect for riscv64", .{});
    return func.finishAir(inst, result, .{ pl_op.operand, extra.lhs, extra.rhs });
}

fn airShuffle(func: *Func, inst: Air.Inst.Index) !void {
    const ty_op = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airShuffle for riscv64", .{});
    return func.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airReduce(func: *Func, inst: Air.Inst.Index) !void {
    const reduce = func.air.instructions.items(.data)[@intFromEnum(inst)].reduce;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else return func.fail("TODO implement airReduce for riscv64", .{});
    return func.finishAir(inst, result, .{ reduce.operand, .none, .none });
}

fn airAggregateInit(func: *Func, inst: Air.Inst.Index) !void {
    const zcu = func.bin_file.comp.module.?;
    const result_ty = func.typeOfIndex(inst);
    const len: usize = @intCast(result_ty.arrayLen(zcu));
    const ty_pl = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const elements: []const Air.Inst.Ref = @ptrCast(func.air.extra[ty_pl.payload..][0..len]);

    const result: MCValue = result: {
        switch (result_ty.zigTypeTag(zcu)) {
            .Struct => {
                const frame_index = try func.allocFrameIndex(FrameAlloc.initSpill(result_ty, zcu));
                if (result_ty.containerLayout(zcu) == .@"packed") {
                    const struct_obj = zcu.typeToStruct(result_ty).?;
                    try func.genInlineMemset(
                        .{ .lea_frame = .{ .index = frame_index } },
                        .{ .immediate = 0 },
                        .{ .immediate = result_ty.abiSize(zcu) },
                    );

                    for (elements, 0..) |elem, elem_i_usize| {
                        const elem_i: u32 = @intCast(elem_i_usize);
                        if ((try result_ty.structFieldValueComptime(zcu, elem_i)) != null) continue;

                        const elem_ty = result_ty.structFieldType(elem_i, zcu);
                        const elem_bit_size: u32 = @intCast(elem_ty.bitSize(zcu));
                        if (elem_bit_size > 64) {
                            return func.fail(
                                "TODO airAggregateInit implement packed structs with large fields",
                                .{},
                            );
                        }

                        const elem_abi_size: u32 = @intCast(elem_ty.abiSize(zcu));
                        const elem_abi_bits = elem_abi_size * 8;
                        const elem_off = zcu.structPackedFieldBitOffset(struct_obj, elem_i);
                        const elem_byte_off: i32 = @intCast(elem_off / elem_abi_bits * elem_abi_size);
                        const elem_bit_off = elem_off % elem_abi_bits;
                        const elem_mcv = try func.resolveInst(elem);

                        _ = elem_byte_off;
                        _ = elem_bit_off;

                        const elem_lock = switch (elem_mcv) {
                            .register => |reg| func.register_manager.lockReg(reg),
                            .immediate => |imm| lock: {
                                if (imm == 0) continue;
                                break :lock null;
                            },
                            else => null,
                        };
                        defer if (elem_lock) |lock| func.register_manager.unlockReg(lock);

                        return func.fail("TODO: airAggregateInit packed structs", .{});
                    }
                } else for (elements, 0..) |elem, elem_i| {
                    if ((try result_ty.structFieldValueComptime(zcu, elem_i)) != null) continue;

                    const elem_ty = result_ty.structFieldType(elem_i, zcu);
                    const elem_off: i32 = @intCast(result_ty.structFieldOffset(elem_i, zcu));
                    const elem_mcv = try func.resolveInst(elem);
                    try func.genSetMem(.{ .frame = frame_index }, elem_off, elem_ty, elem_mcv);
                }
                break :result .{ .load_frame = .{ .index = frame_index } };
            },
            .Array => {
                const elem_ty = result_ty.childType(zcu);
                const frame_index = try func.allocFrameIndex(FrameAlloc.initSpill(result_ty, zcu));
                const elem_size: u32 = @intCast(elem_ty.abiSize(zcu));

                for (elements, 0..) |elem, elem_i| {
                    const elem_mcv = try func.resolveInst(elem);
                    const elem_off: i32 = @intCast(elem_size * elem_i);
                    try func.genSetMem(
                        .{ .frame = frame_index },
                        elem_off,
                        elem_ty,
                        elem_mcv,
                    );
                }
                if (result_ty.sentinel(zcu)) |sentinel| try func.genSetMem(
                    .{ .frame = frame_index },
                    @intCast(elem_size * elements.len),
                    elem_ty,
                    try func.genTypedValue(sentinel),
                );
                break :result .{ .load_frame = .{ .index = frame_index } };
            },
            else => return func.fail("TODO: airAggregate {}", .{result_ty.fmt(zcu)}),
        }
    };

    if (elements.len <= Liveness.bpi - 1) {
        var buf = [1]Air.Inst.Ref{.none} ** (Liveness.bpi - 1);
        @memcpy(buf[0..elements.len], elements);
        return func.finishAir(inst, result, buf);
    }
    var bt = func.liveness.iterateBigTomb(inst);
    for (elements) |elem| try func.feed(&bt, elem);
    return func.finishAirResult(inst, result);
}

fn airUnionInit(func: *Func, inst: Air.Inst.Index) !void {
    const ty_pl = func.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
    const extra = func.air.extraData(Air.UnionInit, ty_pl.payload).data;
    _ = extra;
    return func.fail("TODO implement airUnionInit for riscv64", .{});
    // return func.finishAir(inst, result, .{ extra.ptr, extra.expected_value, extra.new_value });
}

fn airPrefetch(func: *Func, inst: Air.Inst.Index) !void {
    const prefetch = func.air.instructions.items(.data)[@intFromEnum(inst)].prefetch;
    // TODO: RISC-V does have prefetch instruction variants.
    // see here: https://raw.githubusercontent.com/riscv/riscv-CMOs/master/specifications/cmobase-v1.0.1.pdf
    return func.finishAir(inst, .unreach, .{ prefetch.ptr, .none, .none });
}

fn airMulAdd(func: *Func, inst: Air.Inst.Index) !void {
    const pl_op = func.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
    const extra = func.air.extraData(Air.Bin, pl_op.payload).data;
    const result: MCValue = if (func.liveness.isUnused(inst)) .unreach else {
        return func.fail("TODO implement airMulAdd for riscv64", .{});
    };
    return func.finishAir(inst, result, .{ extra.lhs, extra.rhs, pl_op.operand });
}

fn resolveInst(func: *Func, ref: Air.Inst.Ref) InnerError!MCValue {
    const zcu = func.bin_file.comp.module.?;

    // If the type has no codegen bits, no need to store it.
    const inst_ty = func.typeOf(ref);
    if (!inst_ty.hasRuntimeBits(zcu))
        return .none;

    const mcv = if (ref.toIndex()) |inst| mcv: {
        break :mcv func.inst_tracking.getPtr(inst).?.short;
    } else mcv: {
        const ip_index = ref.toInterned().?;
        const gop = try func.const_tracking.getOrPut(func.gpa, ip_index);
        if (!gop.found_existing) gop.value_ptr.* = InstTracking.init(
            try func.genTypedValue(Value.fromInterned(ip_index)),
        );
        break :mcv gop.value_ptr.short;
    };

    return mcv;
}

fn getResolvedInstValue(func: *Func, inst: Air.Inst.Index) *InstTracking {
    const tracking = func.inst_tracking.getPtr(inst).?;
    return switch (tracking.short) {
        .none, .unreach, .dead => unreachable,
        else => tracking,
    };
}

fn genTypedValue(func: *Func, val: Value) InnerError!MCValue {
    const zcu = func.bin_file.comp.module.?;
    const result = try codegen.genTypedValue(
        func.bin_file,
        func.src_loc,
        val,
        zcu.funcOwnerDeclIndex(func.func_index),
    );
    const mcv: MCValue = switch (result) {
        .mcv => |mcv| switch (mcv) {
            .none => .none,
            .undef => .undef,
            .load_symbol => |sym_index| .{ .load_symbol = .{ .sym = sym_index } },
            .immediate => |imm| .{ .immediate = imm },
            .memory => |addr| .{ .memory = addr },
            .load_got, .load_direct, .load_tlv => {
                return func.fail("TODO: genTypedValue {s}", .{@tagName(mcv)});
            },
        },
        .fail => |msg| {
            func.err_msg = msg;
            return error.CodegenFail;
        },
    };
    return mcv;
}

const CallMCValues = struct {
    args: []MCValue,
    return_value: InstTracking,
    stack_byte_count: u31,
    stack_align: Alignment,

    fn deinit(call: *CallMCValues, func: *Func) void {
        func.gpa.free(call.args);
        call.* = undefined;
    }
};

/// Caller must call `CallMCValues.deinit`.
fn resolveCallingConventionValues(
    func: *Func,
    fn_info: InternPool.Key.FuncType,
    var_args: []const Type,
) !CallMCValues {
    const zcu = func.bin_file.comp.module.?;
    const ip = &zcu.intern_pool;

    const param_types = try func.gpa.alloc(Type, fn_info.param_types.len + var_args.len);
    defer func.gpa.free(param_types);

    for (param_types[0..fn_info.param_types.len], fn_info.param_types.get(ip)) |*dest, src| {
        dest.* = Type.fromInterned(src);
    }
    for (param_types[fn_info.param_types.len..], var_args) |*param_ty, arg_ty|
        param_ty.* = func.promoteVarArg(arg_ty);

    const cc = fn_info.cc;
    var result: CallMCValues = .{
        .args = try func.gpa.alloc(MCValue, param_types.len),
        // These undefined values must be populated before returning from this function.
        .return_value = undefined,
        .stack_byte_count = 0,
        .stack_align = undefined,
    };
    errdefer func.gpa.free(result.args);

    const ret_ty = Type.fromInterned(fn_info.return_type);

    switch (cc) {
        .Naked => {
            assert(result.args.len == 0);
            result.return_value = InstTracking.init(.unreach);
            result.stack_align = .@"8";
        },
        .C, .Unspecified => {
            if (result.args.len > 8) {
                return func.fail("RISC-V calling convention does not support more than 8 arguments", .{});
            }

            var ret_int_reg_i: u32 = 0;
            var param_int_reg_i: u32 = 0;

            result.stack_align = .@"16";

            // Return values
            if (ret_ty.zigTypeTag(zcu) == .NoReturn) {
                result.return_value = InstTracking.init(.unreach);
            } else if (!ret_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
                result.return_value = InstTracking.init(.none);
            } else {
                var ret_tracking: [2]InstTracking = undefined;
                var ret_tracking_i: usize = 0;
                var ret_float_reg_i: usize = 0;

                const classes = mem.sliceTo(&abi.classifySystem(ret_ty, zcu), .none);

                for (classes) |class| switch (class) {
                    .integer => {
                        const ret_int_reg = abi.Registers.Integer.function_ret_regs[ret_int_reg_i];
                        ret_int_reg_i += 1;

                        ret_tracking[ret_tracking_i] = InstTracking.init(.{ .register = ret_int_reg });
                        ret_tracking_i += 1;
                    },
                    .float => {
                        const ret_float_reg = abi.Registers.Float.function_ret_regs[ret_float_reg_i];
                        ret_float_reg_i += 1;

                        ret_tracking[ret_tracking_i] = InstTracking.init(.{ .register = ret_float_reg });
                        ret_tracking_i += 1;
                    },
                    .memory => {
                        const ret_int_reg = abi.Registers.Integer.function_ret_regs[ret_int_reg_i];
                        ret_int_reg_i += 1;
                        const ret_indirect_reg = abi.Registers.Integer.function_arg_regs[param_int_reg_i];
                        param_int_reg_i += 1;

                        ret_tracking[ret_tracking_i] = .{
                            .short = .{ .indirect = .{ .reg = ret_int_reg } },
                            .long = .{ .indirect = .{ .reg = ret_indirect_reg } },
                        };
                        ret_tracking_i += 1;
                    },
                    else => return func.fail("TODO: C calling convention return class {}", .{class}),
                };

                result.return_value = switch (ret_tracking_i) {
                    else => return func.fail("ty {} took {} tracking return indices", .{ ret_ty.fmt(zcu), ret_tracking_i }),
                    1 => ret_tracking[0],
                    2 => InstTracking.init(.{ .register_pair = .{
                        ret_tracking[0].short.register, ret_tracking[1].short.register,
                    } }),
                };
            }

            var param_float_reg_i: usize = 0;

            for (param_types, result.args) |ty, *arg| {
                if (!ty.hasRuntimeBitsIgnoreComptime(zcu)) {
                    assert(cc == .Unspecified);
                    arg.* = .none;
                    continue;
                }

                var arg_mcv: [2]MCValue = undefined;
                var arg_mcv_i: usize = 0;

                const classes = mem.sliceTo(&abi.classifySystem(ty, zcu), .none);

                for (classes) |class| switch (class) {
                    .integer => {
                        const param_int_regs = abi.Registers.Integer.function_arg_regs;
                        if (param_int_reg_i >= param_int_regs.len) break;

                        const param_int_reg = param_int_regs[param_int_reg_i];
                        param_int_reg_i += 1;

                        arg_mcv[arg_mcv_i] = .{ .register = param_int_reg };
                        arg_mcv_i += 1;
                    },
                    .float => {
                        const param_float_regs = abi.Registers.Float.function_arg_regs;
                        if (param_float_reg_i >= param_float_regs.len) break;

                        const param_float_reg = param_float_regs[param_float_reg_i];
                        param_float_reg_i += 1;

                        arg_mcv[arg_mcv_i] = .{ .register = param_float_reg };
                        arg_mcv_i += 1;
                    },
                    .memory => {
                        const param_int_regs = abi.Registers.Integer.function_arg_regs;

                        const param_int_reg = param_int_regs[param_int_reg_i];
                        param_int_reg_i += 1;

                        arg_mcv[arg_mcv_i] = .{ .indirect = .{ .reg = param_int_reg } };
                        arg_mcv_i += 1;
                    },
                    else => return func.fail("TODO: C calling convention arg class {}", .{class}),
                } else {
                    arg.* = switch (arg_mcv_i) {
                        else => return func.fail("ty {} took {} tracking arg indices", .{ ty.fmt(zcu), arg_mcv_i }),
                        1 => arg_mcv[0],
                        2 => .{ .register_pair = .{ arg_mcv[0].register, arg_mcv[1].register } },
                    };
                    continue;
                }

                return func.fail("TODO: pass args by stack", .{});
            }
        },
        else => return func.fail("TODO implement function parameters for {} on riscv64", .{cc}),
    }

    result.stack_byte_count = @intCast(result.stack_align.forward(result.stack_byte_count));
    return result;
}

fn wantSafety(func: *Func) bool {
    return switch (func.mod.optimize_mode) {
        .Debug => true,
        .ReleaseSafe => true,
        .ReleaseFast => false,
        .ReleaseSmall => false,
    };
}

fn fail(func: *Func, comptime format: []const u8, args: anytype) InnerError {
    @setCold(true);
    assert(func.err_msg == null);
    func.err_msg = try ErrorMsg.create(func.gpa, func.src_loc, format, args);
    return error.CodegenFail;
}

fn failSymbol(func: *Func, comptime format: []const u8, args: anytype) InnerError {
    @setCold(true);
    assert(func.err_msg == null);
    func.err_msg = try ErrorMsg.create(func.gpa, func.src_loc, format, args);
    return error.CodegenFail;
}

fn parseRegName(name: []const u8) ?Register {
    return std.meta.stringToEnum(Register, name);
}

fn typeOf(func: *Func, inst: Air.Inst.Ref) Type {
    const zcu = func.bin_file.comp.module.?;
    return func.air.typeOf(inst, &zcu.intern_pool);
}

fn typeOfIndex(func: *Func, inst: Air.Inst.Index) Type {
    const zcu = func.bin_file.comp.module.?;
    return func.air.typeOfIndex(inst, &zcu.intern_pool);
}

fn hasFeature(func: *Func, feature: Target.riscv.Feature) bool {
    return Target.riscv.featureSetHas(func.target.cpu.features, feature);
}

pub fn errUnionPayloadOffset(payload_ty: Type, zcu: *Zcu) u64 {
    if (!payload_ty.hasRuntimeBitsIgnoreComptime(zcu)) return 0;
    const payload_align = payload_ty.abiAlignment(zcu);
    const error_align = Type.anyerror.abiAlignment(zcu);
    if (payload_align.compare(.gte, error_align) or !payload_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
        return 0;
    } else {
        return payload_align.forward(Type.anyerror.abiSize(zcu));
    }
}

pub fn errUnionErrorOffset(payload_ty: Type, zcu: *Zcu) u64 {
    if (!payload_ty.hasRuntimeBitsIgnoreComptime(zcu)) return 0;
    const payload_align = payload_ty.abiAlignment(zcu);
    const error_align = Type.anyerror.abiAlignment(zcu);
    if (payload_align.compare(.gte, error_align) and payload_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
        return error_align.forward(payload_ty.abiSize(zcu));
    } else {
        return 0;
    }
}

fn promoteInt(func: *Func, ty: Type) Type {
    const mod = func.bin_file.comp.module.?;
    const int_info: InternPool.Key.IntType = switch (ty.toIntern()) {
        .bool_type => .{ .signedness = .unsigned, .bits = 1 },
        else => if (ty.isAbiInt(mod)) ty.intInfo(mod) else return ty,
    };
    for ([_]Type{
        Type.c_int,      Type.c_uint,
        Type.c_long,     Type.c_ulong,
        Type.c_longlong, Type.c_ulonglong,
    }) |promote_ty| {
        const promote_info = promote_ty.intInfo(mod);
        if (int_info.signedness == .signed and promote_info.signedness == .unsigned) continue;
        if (int_info.bits + @intFromBool(int_info.signedness == .unsigned and
            promote_info.signedness == .signed) <= promote_info.bits) return promote_ty;
    }
    return ty;
}

fn promoteVarArg(func: *Func, ty: Type) Type {
    if (!ty.isRuntimeFloat()) return func.promoteInt(ty);
    switch (ty.floatBits(func.target.*)) {
        32, 64 => return Type.f64,
        else => |float_bits| {
            assert(float_bits == func.target.c_type_bit_size(.longdouble));
            return Type.c_longdouble;
        },
    }
}
