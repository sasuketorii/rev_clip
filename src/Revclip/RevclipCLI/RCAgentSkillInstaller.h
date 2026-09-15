#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Synchronous native installer. No interpreter, subprocess, app launch or network access.
/// Compile the implementation with ARC and -fobjc-arc-exceptions for FD cleanup on failures.
@interface RCAgentSkillInstaller : NSObject
/// arguments starts with inspect/install (no argv[0] or agents prefix).
/// Options: --app Revclip|revclip-demo (default Revclip), --home ABSOLUTE_PATH,
/// repeatable --provider ID (also comma-separated), --source ABSOLUTE_PATH.
/// --source accepts AgentSupport or its revclip child. Outside an app layout the
/// executing native binary is used as the test payload; inside an app, its current
/// Contents/Helpers/revclip is used. Without --source, use the matching enclosing app,
/// /Applications/<app>.app, or <home>/Applications/<app>.app, in that order.
/// Installs SKILL.md, agents/openai.yaml and scripts/revclip (native executable),
/// plus the compatible schema-1 ownership manifest. Never runs installed payloads.
/// Prints one JSON report to stdout; returns 0 success, 1 conflict/failure, 2 bad arguments.
+ (int)runArguments:(NSArray<NSString *> *)arguments;
@end
NS_ASSUME_NONNULL_END
