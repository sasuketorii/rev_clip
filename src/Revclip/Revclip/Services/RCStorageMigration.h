#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Bootstraps protected storage before any database query or clipboard monitoring.
@interface RCStorageMigration : NSObject
+ (BOOL)prepareDatabaseAtPath:(NSString *)path error:(NSError **)error;
+ (BOOL)migrateClipFilesBesideDatabase:(NSString *)path error:(NSError **)error;
+ (BOOL)validateMigrationArtifactsBesideDatabase:(NSString *)path error:(NSError **)error;
+ (BOOL)removeMigrationArtifactsBesideDatabase:(NSString *)path error:(NSError **)error;
+ (BOOL)validatePrivateDirectory:(NSString *)path create:(BOOL)create;
@end
NS_ASSUME_NONNULL_END
