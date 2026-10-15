#import "Solver.h"

@implementation ArrowCell
@end

@implementation ArrowGameSolver

+ (NSArray<ArrowCell *> *)solveGrid:(NSArray<NSArray<NSNumber *> *> *)grid {
    if (!grid || grid.count == 0) return nil;
    NSInteger rows = grid.count;
    NSInteger cols = grid[0].count;

    // Build mutable working grid
    NSMutableArray<NSMutableArray<NSNumber *> *> *work = [NSMutableArray arrayWithCapacity:rows];
    for (NSInteger r = 0; r < rows; r++) {
        NSMutableArray<NSNumber *> *row = [NSMutableArray arrayWithCapacity:cols];
        for (NSInteger c = 0; c < cols; c++) {
            [row addObject:grid[r][c]];
        }
        [work addObject:row];
    }

    NSMutableArray<ArrowCell *> *solution = [NSMutableArray array];
    if ([self backtrack:work solution:solution rows:rows cols:cols]) {
        return [solution copy];
    }
    return nil;
}

+ (BOOL)backtrack:(NSMutableArray<NSMutableArray<NSNumber *> *> *)grid
        solution:(NSMutableArray<ArrowCell *> *)solution
            rows:(NSInteger)rows
            cols:(NSInteger)cols {
    // Check if solved
    BOOL anyLeft = NO;
    for (NSInteger r = 0; r < rows && !anyLeft; r++) {
        for (NSInteger c = 0; c < cols && !anyLeft; c++) {
            if ([grid[r][c] integerValue] != ArrowDirectionNone) {
                anyLeft = YES;
            }
        }
    }
    if (!anyLeft) return YES;

    // Find all currently removable arrows
    NSMutableArray<ArrowCell *> *candidates = [NSMutableArray array];
    for (NSInteger r = 0; r < rows; r++) {
        for (NSInteger c = 0; c < cols; c++) {
            ArrowDirection dir = [grid[r][c] integerValue];
            if (dir == ArrowDirectionNone) continue;
            if ([self canSlideOut:grid row:r col:c direction:dir rows:rows cols:cols]) {
                ArrowCell *cell = [[ArrowCell alloc] init];
                cell.direction = dir;
                cell.row = r;
                cell.col = c;
                [candidates addObject:cell];
            }
        }
    }

    if (candidates.count == 0) return NO; // dead end

    // Try each candidate; prefer fewer-blockers heuristic could go here
    for (ArrowCell *cell in candidates) {
        ArrowDirection savedDir = [grid[cell.row][cell.col] integerValue];
        grid[cell.row][cell.col] = @(ArrowDirectionNone);
        [solution addObject:cell];

        if ([self backtrack:grid solution:solution rows:rows cols:cols]) {
            return YES;
        }

        // undo
        [solution removeLastObject];
        grid[cell.row][cell.col] = @(savedDir);
    }

    return NO;
}

+ (BOOL)canSlideOut:(NSMutableArray<NSMutableArray<NSNumber *> *> *)grid
                row:(NSInteger)row
                col:(NSInteger)col
          direction:(ArrowDirection)direction
               rows:(NSInteger)rows
               cols:(NSInteger)cols {
    NSInteger dr = 0, dc = 0;
    switch (direction) {
        case ArrowDirectionUp:    dr = -1; break;
        case ArrowDirectionDown:  dr =  1; break;
        case ArrowDirectionLeft:  dc = -1; break;
        case ArrowDirectionRight: dc =  1; break;
        default: return NO;
    }

    NSInteger r = row + dr;
    NSInteger c = col + dc;
    while (r >= 0 && r < rows && c >= 0 && c < cols) {
        if ([grid[r][c] integerValue] != ArrowDirectionNone) {
            return NO;
        }
        r += dr;
        c += dc;
    }
    return YES;
}

@end
