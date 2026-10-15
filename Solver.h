#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ArrowDirection) {
    ArrowDirectionNone = 0,
    ArrowDirectionUp,
    ArrowDirectionDown,
    ArrowDirectionLeft,
    ArrowDirectionRight
};

@interface ArrowCell : NSObject
@property (nonatomic, assign) ArrowDirection direction;
@property (nonatomic, assign) NSInteger row;
@property (nonatomic, assign) NSInteger col;
@end

@interface ArrowGameSolver : NSObject

+ (NSArray<ArrowCell *> *)solveGrid:(NSArray<NSArray<NSNumber *> *> *)grid;

@end
