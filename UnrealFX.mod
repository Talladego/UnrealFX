<?xml version="1.0" encoding="UTF-8"?>
<ModuleFile xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <UiMod name="UnrealFX" version="2.0.0" date="2026-10-30">
        <VersionSettings gameVersion="1.4.8" windowsVersion="1.0" savedVariablesVersion="1.0" />
        <Author name="Ztil, Wholdar" email="" />
        <Description text="Based on UnrealDBAnnouncer by ztil / Wholdar (RoR forums). UT-style kill announcer with world-attached FX overlays. Plays WAVs via UnrealFX.exe / UnrealFX.py (OBS-friendly window). Supports RvR/PVE kills, multi-kill streaks, ready check / scenario / fortress / LOTD alerts, and grow/spin corpse FX. Slash: /ufx. Disable UnrealDBAnnouncer if both are installed." />
        <WARInfo>
            <Categories>
                <Category name="RVR" />
                <Category name="GROUPING" />
            </Categories>
            <Careers>
                <Career name="BLACKGUARD" />
                <Career name="WITCH_ELF" />
                <Career name="DISCIPLE" />
                <Career name="SORCERER" />
                <Career name="IRON_BREAKER" />
                <Career name="SLAYER" />
                <Career name="RUNE_PRIEST" />
                <Career name="ENGINEER" />
                <Career name="BLACK_ORC" />
                <Career name="CHOPPA" />
                <Career name="SHAMAN" />
                <Career name="SQUIG_HERDER" />
                <Career name="WITCH_HUNTER" />
                <Career name="KNIGHT" />
                <Career name="BRIGHT_WIZARD" />
                <Career name="WARRIOR_PRIEST" />
                <Career name="CHOSEN" />
                <Career name="MARAUDER" />
                <Career name="ZEALOT" />
                <Career name="MAGUS" />
                <Career name="SWORDMASTER" />
                <Career name="SHADOW_WARRIOR" />
                <Career name="WHITE_LION" />
                <Career name="ARCHMAGE" />
            </Careers>
        </WARInfo>
        <Files>
                <File name="UnrealFX.xml" />
                <File name="UnrealFX.lua" />
        </Files>
        <SavedVariables>
            <SavedVariable name="UnrealFX.settings" />
        </SavedVariables>
        <OnInitialize>
            <callFunction name="UnrealFX.Initialize"/>
        </OnInitialize>
        <!-- Drive FX shake/fade here — world-attached windows stop OnUpdate when the entity dies. -->
        <OnUpdate>
            <CallFunction name="UnrealFX.OnFxUpdate" />
        </OnUpdate>
        <OnShutdown>
            <CallFunction name="UnrealFX.clearLogFile" />
        </OnShutdown>
    </UiMod>
</ModuleFile>
