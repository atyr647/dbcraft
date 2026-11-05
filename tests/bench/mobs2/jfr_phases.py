#!/usr/bin/env python3
"""Where the vanilla server thread spends its time: inclusive share of the CPU samples of a Java Flight Recorder file (jdk.ExecutionSample of the thread "Server thread") per phase, by the
frames on the sampled stack.  docs/WHY-MOBS-COST.md.   usage: jfr_phases.py FILE.jfr [--top 25]
A sample counts for every phase whose marker method is somewhere on its stack (inclusive), so the phases overlap where they nest (the move inside the AI step, say)."""
import re, subprocess, sys, collections, shutil

PHASES = [  # (label, [substrings of "class.method" frames that put a sample in the phase])
    ("whole server thread tick", ["MinecraftServer.tickServer"]),
    ("level tick (ServerLevel.tick)", ["ServerLevel.tick("]),
    ("entities: per-entity tick (ServerLevel.tickNonPassenger / guardEntityTick)", ["ServerLevel.tickNonPassenger", "ServerLevel.guardEntityTick"]),
    ("  entity.checkDespawn (nearest-player scan per mob per tick)", ["Mob.checkDespawn"]),
    ("  Mob.serverAiStep (sensing + goals + navigation + controls)", ["Mob.serverAiStep"]),
    ("    goal selectors: GoalSelector.tick (canUse of every non-running goal, every 2nd tick)", ["GoalSelector.tick("]),
    ("    PathNavigation.tick / path following", ["PathNavigation.tick"]),
    ("    path computation (A*: PathFinder.findPath / createPath)", ["PathFinder.findPath", "PathNavigation.createPath"]),
    ("    MoveControl.tick", ["MoveControl.tick"]),
    ("    LookControl.tick", ["LookControl.tick"]),
    ("  LivingEntity.aiStep (travel, fluids, effects, pushEntities)", ["LivingEntity.aiStep"]),
    ("    LivingEntity.travel / Entity.move (collision)", ["LivingEntity.travel", "Entity.move("]),
    ("    collision shapes (Entity.collide / getBlockCollisions)", ["Entity.collide", "CollisionGetter.getBlockCollisions", "BlockCollisions"]),
    ("    LivingEntity.pushEntities (entity-entity collision query)", ["LivingEntity.pushEntities", "LivingEntity.doPush", "Entity.push("]),
    ("  Entity.baseTick / checks (fluids, block effects)", ["Entity.baseTick", "Entity.applyEffectsFromBlocks", "Entity.updateInWaterStateAndDoFluidPushing"]),
    ("tracking: ChunkMap.tick (updatePlayers, sendChanges)", ["ChunkMap.tick("]),
    ("  ServerEntity.sendChanges (delta, motion, rotation packets)", ["ServerEntity.sendChanges"]),
    ("  TrackedEntity.updatePlayer(s) (who sees whom)", ["TrackedEntity.updatePlayer"]),
    ("  packet encode / send (Connection.send, PacketEncoder)", ["Connection.send", "PacketEncoder", "ServerGamePacketListenerImpl.send"]),
    ("chunk system (ServerChunkCache.tick, chunk ticking, tickets)", ["ServerChunkCache.tick"]),
    ("network handling / other threads on the server thread (runAllTasks)", ["BlockableEventLoop.runAllTasks", "MinecraftServer.runAllTasks"]),
    ("garbage collection (JFR GC events are not stack samples: see the GC line below)", ["@@never@@"]),
]

def main():
    f = sys.argv[1]
    top = 25
    if "--top" in sys.argv: top = int(sys.argv[sys.argv.index("--top") + 1])
    jfr = shutil.which("jfr") or "/usr/lib/jvm/java-25-openjdk-amd64/bin/jfr"
    out = subprocess.run([jfr, "print", "--events", "jdk.ExecutionSample", "--stack-depth", "96", f], capture_output=True, text=True, env={"JAVA_TOOL_OPTIONS": ""}).stdout
    events = out.split("jdk.ExecutionSample {")
    n = 0; counts = collections.Counter(); leaf = collections.Counter(); methods = collections.Counter()
    for ev in events[1:]:
        m = re.search(r'sampledThread = "([^"]*)"', ev)
        if not m or m.group(1) != "Server thread": continue
        frames = re.findall(r"^\s+([\w.$<>]+)\(.*\)\s+line:", ev, re.M)
        if not frames: continue
        n += 1
        text = "\n".join(frames)
        for label, keys in PHASES:
            if any(k.rstrip("(") in text for k in keys): counts[label] += 1
        leaf[frames[0]] += 1
        for fr in set(frames): methods[fr] += 1
    print(f"{f}: {n} samples of the Server thread")
    for label, keys in PHASES:
        if counts[label]: print(f"  {100.0 * counts[label] / n:5.1f} %  {label}")
    print("  top frames (self time):")
    for fr, c in leaf.most_common(top): print(f"  {100.0 * c / n:5.1f} %  {fr}")

main()
