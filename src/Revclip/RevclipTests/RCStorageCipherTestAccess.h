#import <Foundation/Foundation.h>
@interface RCStorageCipher : NSObject
+ (instancetype)shared;
+ (BOOL)isEncryptedData:(NSData *)data;
- (NSData *)databaseKeyWithError:(NSError **)error;
- (NSData *)decryptData:(NSData *)data error:(NSError **)error;
- (NSData *)readDataAtPath:(NSString *)path allowPlaintext:(BOOL)allow error:(NSError **)error;
- (BOOL)writeData:(NSData *)data toPath:(NSString *)path error:(NSError **)error;
@end
