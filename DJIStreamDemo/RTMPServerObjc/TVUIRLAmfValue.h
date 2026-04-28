//
//  TVUIRLAmfValue.h
//  DJIStreamDemo
//
//  AMF0 值类型的 ObjC 表示。Swift 的 enum AsValue 在 ObjC 中通过类层次 + Type 枚举模拟。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TVUIRLAmfValueType) {
    TVUIRLAmfValueTypeNumber,
    TVUIRLAmfValueTypeBoolean,
    TVUIRLAmfValueTypeString,
    TVUIRLAmfValueTypeObject,
    TVUIRLAmfValueTypeNull,
    TVUIRLAmfValueTypeUndefined,
    TVUIRLAmfValueTypeReference,
    TVUIRLAmfValueTypeEcmaArray,
    TVUIRLAmfValueTypeStrictArray,
    TVUIRLAmfValueTypeDate,
    TVUIRLAmfValueTypeUnsupported,
    TVUIRLAmfValueTypeXmlDocument,
    TVUIRLAmfValueTypeTypedObject,
    TVUIRLAmfValueTypeAvmplush,
};

@interface TVUIRLAmfValue : NSObject

@property (nonatomic, readonly) TVUIRLAmfValueType type;

+ (instancetype)numberValue:(double)value;
+ (instancetype)boolValue:(BOOL)value;
+ (instancetype)stringValue:(NSString *)value;
+ (instancetype)objectValue:(NSDictionary<NSString *, TVUIRLAmfValue *> *)value;
+ (instancetype)nullValue;
+ (instancetype)undefinedValue;
+ (instancetype)ecmaArrayValue:(NSDictionary<NSString *, TVUIRLAmfValue *> *)value;
+ (instancetype)strictArrayValue:(NSArray<TVUIRLAmfValue *> *)value;
+ (instancetype)dateValue:(NSDate *)value;
+ (instancetype)xmlDocumentValue:(NSString *)value;
+ (instancetype)typedObjectValue:(NSDictionary<NSString *, TVUIRLAmfValue *> *)value type:(NSString *)typeName;
+ (instancetype)unsupportedValue;
+ (instancetype)avmplushValue;
+ (instancetype)referenceValue;

- (double)doubleValue;
- (BOOL)boolValue;
- (nullable NSString *)stringValue;
- (nullable NSDictionary<NSString *, TVUIRLAmfValue *> *)objectValue;
- (nullable NSArray<TVUIRLAmfValue *> *)strictArrayValue;
- (nullable NSDate *)dateValue;
- (nullable NSString *)xmlDocumentString;
- (nullable NSString *)typedObjectName;

@end

NS_ASSUME_NONNULL_END
