#define SERVER_ONLY
#include "KnightCommon.as";
#include "Knocked.as";
#include "Logging.as";

const float HOVER_MIN = 56.0;
const float HOVER_MAX = 72.0;
const int ATTACK_DELAY = 4; // delay attacks from the optimum number

namespace Strategy
{
    enum _
    {
        seek, // move near to the enemy
        hover, // stay just out of reach
        closecombat, // if we end up close to the enemy (handle shielding and jabs)
        push // go in with slash if an opportunity is seen
    }
}

namespace CombatState
{
    enum _
    {
        normal,
        charging,
        jabbing,
        slashing,
        powerslashing,
        shielding,
        shieldsliding,
        knocked
    }
}

void onInit(CBrain@ this)
{
    SetStrategy(this, Strategy::seek);
	this.getCurrentScript().removeIfTag = "dead";
}

void SetStrategy(CBrain@ this, u8 strat) {
    //log("SetStrategy", "Setting strategy to " + GetStrategyName(strat));
    this.getBlob().set_u8("Strategy", strat);
}

u8 GetStrategy(CBrain@ this) {
    return this.getBlob().get_u8("Strategy");
}

string GetStrategyName(u8 strat) {
    if (strat == Strategy::seek)
        return "seek";
    else if (strat == Strategy::hover)
        return "hover";
    else if (strat == Strategy::closecombat)
        return "closecombat";
    else if (strat == Strategy::push)
        return "push";
    else
        return "UNKNOWN STRATEGY";
}

u8 GetCombatState(CBlob@ blob) {
    KnightInfo@ knight;
    blob.get("knightInfo", @knight);

    if (getKnocked(blob) > 0)
        return CombatState::knocked;
    else if (knight.state == KnightStates::normal)
        return CombatState::normal;
    else if (knight.state == KnightStates::sword_drawn)
        return CombatState::charging;
    else if (isShieldState(knight.state)) {
        if (knight.slideTime > 0) {
            return CombatState::shieldsliding;
        }
        else {
            return CombatState::shielding;
        }
    }
    else if (inMiddleOfAttack(knight.state)) {
        if (knight.state == KnightStates::sword_power)
            return CombatState::slashing;
        else if (knight.state == KnightStates::sword_power_super)
            return CombatState::powerslashing;
        else
            return CombatState::jabbing;
    }
    return 255;
}

bool IsAttackingCombatState(u8 state) {
    return state == CombatState::jabbing ||
        state == CombatState::slashing ||
        state == CombatState::powerslashing;
}

void onTick(CBrain@ this) {
    // Check that knightInfo is set properly
    if (GetKnightInfo(this) is null) {
        log("onTick", "knightInfo not set properly!");
        return;
    }

    // Update target if needed
    CBlob@ blob = this.getBlob();
	CBlob@ target = this.getTarget();
	if (target is null || target.hasTag("dead"))
	{
        UpdateTarget(this);
        return;
    }

    u8 strategy = GetStrategy(this);
    u8 thisCombatState = GetCombatState(blob);
    u8 targetCombatState = GetCombatState(target);
    f32 targetDist = blob.getDistanceTo(target);
    u8 targetSwordTimer = GetSwordTimer(target.getBrain());
    Aim(this, target.getPosition());

    if (thisCombatState == CombatState::knocked) {
        //log("onTick", "Knocked! " + getKnocked(blob));
        return;
    }

    if (strategy == Strategy::seek) {
        if (targetDist < HOVER_MAX) {
            SetStrategy(this, Strategy::hover);
        }
        else {
            MoveToTarget(this);
        }
    }
    else if (strategy == Strategy::hover) {
        if (targetDist > HOVER_MAX) {
            SetStrategy(this, Strategy::seek);
        }
        else if (targetDist < HOVER_MIN) {
            SetStrategy(this, Strategy::closecombat);
        }
        else {
            // In a good hover range
            //log("onTick", "In good hover range");
            if (thisCombatState == CombatState::normal || thisCombatState == CombatState::shielding) {
                if (!IsAttackingCombatState(targetCombatState) &&
                        targetCombatState != CombatState::charging) {
                    //log("onTick", "Beginning charge");
                    ChargeAttack(this);
                }
            }
            else if (thisCombatState == CombatState::charging) {
                //log("onTick", "Doing charge");
                u8 swordTimer = GetSwordTimer(this);

                if (swordTimer == KnightVars::slash_charge_limit - 1) {
                    // Force release because we'll be stunned if not
					//log("onTick", "Hit limit");
                    ReleaseAttack(this);
                }
                else if (CanDoubleSlash(this) && DoSlashSimulation(blob, target, true)) {
                    //log("onTick", "Simulation passed for double slash so releasing");
                    ReleaseAttack(this);
                    SetStrategy(this, Strategy::push);
                }
                else if (CanSlash(this) && DoSlashSimulation(blob, target) && targetCombatState != CombatState::shielding) {
                    //log("onTick", "Simulation passed and enemy not shielding so detected: releasing");
                    ReleaseAttack(this);
                    SetStrategy(this, Strategy::push);
                }
                else {
                    ChargeAttack(this);
                }
            }
            
            // Move to optimal hover dist
            float optimalHoverDist = (HOVER_MIN + HOVER_MAX)*0.5;
            if (targetDist < optimalHoverDist)
                MoveAwayFromTarget(this);
            else
                MoveToTarget(this);
        }
    }
    else if (strategy == Strategy::closecombat) {
        if (targetDist > HOVER_MIN) {
            SetStrategy(this, Strategy::hover);
        }
        else {
            if (IsAttackingCombatState(thisCombatState)) {
                //log("onTick", "In attacking state");
                MoveToTarget(this);

                if (thisCombatState == CombatState::powerslashing &&
                        !GetKnightInfo(this).doubleslash &&
                        GetSwordTimer(this) > ATTACK_DELAY * 2) {
                    ChargeAttack(this);
                    //log("onTick", "Releasing second slash");
                }
            }
            else if (thisCombatState == CombatState::charging) {
                if (InAttackRange(blob, target) && (
                            targetCombatState == CombatState::shieldsliding ||
                            targetCombatState != CombatState::shielding)) {
                    if (targetCombatState == CombatState::shieldsliding &&
                            CanSlash(this)) {
                        //log("onTick", "Slashing shield sliding enemy");
                        ReleaseAttack(this);
                        DoJump(this);
                    }
                    else if (targetCombatState != CombatState::shielding) {
                        //log("onTick", "Attacking non-shielding enemy");
                        ReleaseAttack(this);
                    }
                }
                else if (CanDoubleSlash(this)) {
                    //log("onTick", "In closecombat and can double slash");
                    ReleaseAttack(this);
                }
                else {
                    //log("onTick", "Charging attack");
                    ChargeAttack(this);
                }

                MoveToTarget(this);
            }
            else {
                if (IsAttackingCombatState(targetCombatState)) {
                    DoShield(this);
                    MoveAwayFromTarget(this, true);
                }
                else if (targetCombatState == CombatState::charging) {
                    if (InAttackRange(blob, target) && (
                                targetSwordTimer > 8 && targetSwordTimer < 16 ||
                                targetSwordTimer > 24 && targetSwordTimer < 39)) {
                        // Counter jab
                        //log("onTick", "Counterjabbing");
                        ChargeAttack(this);
                        MoveToTarget(this);
                    }
                    else {
                        DoShield(this);
                        MoveAwayFromTarget(this, true);
                    }
                }
                else {
                    ChargeAttack(this);
                    MoveToTarget(this);
                }
            }
        }
    }
    else if (strategy == Strategy::push) {
        if (thisCombatState == CombatState::slashing ||
                thisCombatState == CombatState::powerslashing) {
            if (CanTriggerSecondSlash(this, thisCombatState)) {
                ChargeAttack(this);
            }
            MoveToTarget(this);
        }
        else {
            if (targetDist < HOVER_MIN) {
                SetStrategy(this, Strategy::closecombat);
            }
            else {
                SetStrategy(this, Strategy::hover);
            }
        }
    }
}

bool UpdateTarget(CBrain@ this) {
    // Returns true if we have an active target, false if not
    CBlob@[] playerBlobs;
    CBlob@[] potentialTargets;
    getBlobsByTag("player", playerBlobs);

    for (int i=0; i < playerBlobs.length; i++) {
        CBlob@ blob = playerBlobs[i];
        if (blob !is this.getBlob() && !blob.hasTag("dead")) {
            potentialTargets.push_back(blob);
        }
    }

    bool foundTarget = false;
    uint16 closestBlobNetID;
    float closestDist = 99999.0;
    for (int i=0; i < potentialTargets.length; i++) {
        CBlob@ blob = potentialTargets[i];
        float dist = blob.getDistanceTo(this.getBlob());
        if (dist < closestDist) {
            foundTarget = true;
            closestDist = dist;
            closestBlobNetID = blob.getNetworkID();
        }
    }

    if (foundTarget) {
        this.SetTarget(getBlobByNetworkID(closestBlobNetID));
        return true;
    }
    else
        return false;
}

void MoveToTarget(CBrain@ this) {
    CBlob@ target = this.getTarget();
    CBlob@ blob = this.getBlob();
    Vec2f delta = target.getPosition() - blob.getPosition();
    Aim(this, target.getPosition());

    if (delta.x > 0) {
        blob.setKeyPressed(key_right, true);
        blob.SetFacingLeft(false);
    }
    else {
        blob.setKeyPressed(key_left, true);
        blob.SetFacingLeft(true);
    }

    if (delta.y < -8.0) {
        blob.setKeyPressed(key_up, true);
    }
    else {
        blob.setKeyPressed(key_up, false);
    }
}

void MoveAwayFromTarget(CBrain@ this, bool stayFacingThem = false) {
    CBlob@ target = this.getTarget();
    CBlob@ blob = this.getBlob();
    Vec2f delta = target.getPosition() - blob.getPosition();

    // Aim away from target
    if (!stayFacingThem) {
        Aim(this, blob.getPosition() - delta);
    }

    if (delta.x > 0) {
        blob.setKeyPressed(key_left, true);
        blob.SetFacingLeft(true);
    }
    else {
        blob.setKeyPressed(key_right, true);
        blob.SetFacingLeft(false);
    }
}

KnightInfo@ GetKnightInfo(CBrain@ this) {
    KnightInfo@ knight;
    this.getBlob().get("knightInfo", @knight);
    return knight;
}

u8 GetKnightState(CBrain@ this) {
    return GetKnightInfo(this).state;
}

string GetKnightStateName(CBrain@ this) {
    u8 state = GetKnightState(this);

    if (state == KnightStates::normal) return "normal";
    else if (state == KnightStates::shielding) return "shielding";
    else if (state == KnightStates::shielddropping) return "shielddropping";
    else if (state == KnightStates::shieldgliding) return "shieldgliding";
    else if (state == KnightStates::sword_drawn) return "sword_drawn";
    else if (state == KnightStates::sword_cut_mid) return "sword_cut_mid";
    else if (state == KnightStates::sword_cut_mid_down) return "sword_cut_mid_down";
    else if (state == KnightStates::sword_cut_up) return "sword_cut_up";
    else if (state == KnightStates::sword_cut_down) return "sword_cut_down";
    else if (state == KnightStates::sword_power) return "sword_power";
    else if (state == KnightStates::sword_power_super) return "sword_power_super";
    else return "UNKNOWN STATE " + state;
}

u8 GetSwordTimer(CBrain@ this) {
    return GetKnightInfo(this).swordTimer;
}

void Aim(CBrain@ this, Vec2f pos) {
    this.getBlob().setAimPos(pos);
}

void DoShield(CBrain@ this) {
    this.getBlob().setKeyPressed(key_action2, true);
}

void DoJump(CBrain@ this) {
    this.getBlob().setKeyPressed(key_up, true);
}

void ChargeAttack(CBrain@ this) {
    this.getBlob().setKeyPressed(key_action1, true);
}

void ReleaseAttack(CBrain@ this) {
    DoJump(this);
    this.getBlob().setKeyPressed(key_action1, false);
}

bool CanJab(CBrain@ this) {
    return GetKnightState(this) == KnightStates::sword_drawn;
}

bool CanSlash(CBrain@ this) {
    return GetKnightState(this) == KnightStates::sword_drawn &&
        GetSwordTimer(this) > KnightVars::slash_charge + ATTACK_DELAY;
}

bool CanDoubleSlash(CBrain@ this) {
    return GetKnightState(this) == KnightStates::sword_drawn &&
        GetSwordTimer(this) > KnightVars::slash_charge_level2 + ATTACK_DELAY;
}

bool CanTriggerSecondSlash(CBrain@ this, u8 thisCombatState) {
    return thisCombatState == CombatState::powerslashing &&
            !GetKnightInfo(this).doubleslash &&
            GetSwordTimer(this) > ATTACK_DELAY * 2;
}

f32 GetAttackRange(CBrain@ this) {
    CBlob@ blob = this.getBlob();
	Vec2f vel = blob.getVelocity();
    Vec2f thinghy(1,0);
	f32 attack_distance = Maths::Min(DEFAULT_ATTACK_DISTANCE + Maths::Max(0.0f, 1.75f * blob.getShape().vellen * (vel * thinghy)), MAX_ATTACK_DISTANCE);
    return blob.getRadius() + attack_distance;
}

bool HasTempo(CBlob@ this, CBlob@ other) {
    // Returns true if this has been charging attack longer than other 
    if (other.getName() != "knight")
        return true;
    else {
        KnightInfo@ thisKnight;
        KnightInfo@ otherKnight;
        this.get("knightInfo", @thisKnight);
        other.get("knightInfo", @otherKnight);

        bool thisIsCharging = thisKnight.state == KnightStates::sword_drawn;
        bool otherIsCharging = otherKnight.state == KnightStates::sword_drawn;
        if (thisIsCharging && !otherIsCharging)
            return true;
        else if (!thisIsCharging && otherIsCharging)
            return false;
        else if (thisIsCharging && otherIsCharging) {
            return thisKnight.swordTimer >= otherKnight.swordTimer;
        }
        else {
            return false;
        }
    }
}

bool InAttackRange(CBlob@ this, CBlob@ other) {
    float attackRange = GetAttackRange(this.getBrain());
    float dist = Maths::Abs(other.getPosition().x - this.getPosition().x) - other.getRadius();
    return dist < attackRange;
}

bool DoSlashSimulation(CBlob@ this, CBlob@ other, bool doubleSlash = false) {
    /* Performs a simplified physics simulation to decide
     * whether, if 'this' slashes now, 'other' will be hit.
     * Returns true/false if other will be hit.
     */
    float maxDist = 40.0;
    if (doubleSlash) {
        maxDist *= 1.6;
    }

    float dist = Maths::Abs(other.getPosition().x - this.getPosition().x) - other.getRadius();
    return dist < maxDist;

    /*
    float attackRange = GetAttackRange(this.getBrain());
    float thisX = this.getPosition().x;
    float otherX = other.getPosition().x;
    float thisVelX = this.getVelocity().x;
    float otherVelX = other.getVelocity().x;
    int thisAccelDir = GetAccelDirection(this);
    int otherAccelDir = GetAccelDirection(other);
    float normalVelX = 2.75;
    float normalForceX = 30.0;
    float slashMoveForce = 34.0; // knight mass * 0.5
    float fakeSlashTime = KnightVars::slash_time;
    if (doubleSlash) fakeSlashTime *= 2;

    // A = F/M
    // V = 0.5 * M * A^2

    for (int iter=0; iter < fakeSlashTime; iter++) {
        // Slash hit detection
        // Find closest point on enemy to us
        float dist = Maths::Abs(otherX - thisX) - other.getRadius();
        if (dist < attackRange) {
            // We hit with slash
            //log("DoSlashSimulation", "Hit detected on iteration " + iter);
            return true;
        }
        
        // Physics update
        // this
        float thisTotalForceX = (normalForceX + slashMoveForce) * thisAccelDir;
        float a = thisTotalForceX / this.getMass();
        float vAdd = 0.5 * this.getMass() * Math::Pow(a, 2);

        // other
        float otherTotalForceX = (normalForceX + slashMoveForce) * thisAccelDir;
        thisX += thisVelX;
        otherX += otherVelX;
    }

    //log("DoSlashSimulation", "No hit detected");
    return false;
    */
}

int GetAccelDirection(CBlob@ blob) {
    // Looks at blob key presses and returns -1, 0 or 1
    // representing the direction the blob wants to move in.
    int dir = 0;
    if (blob.isKeyPressed(key_left))
        dir = -1;
    else if (blob.isKeyPressed(key_right))
        dir = 1;

    return dir;
}
