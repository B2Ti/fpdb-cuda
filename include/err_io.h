#pragma once
/**
 * My personal preference for printing to stderr is
 * [INFO] for just information that is not directly related to any issues
 * eg idk rn
 * [WARNING] for things that will not cause immediate issues but can be concerning to the program
 * eg NULL was passed to one of my free functions
 * the function will emit a warning to stderr and return
 * [ERROR] for things that cause issues to the running process
 * eg in array indexing
 *  - if the array pointer is NULL
 *  - if the index is out of bounds
 */

#include <stdio.h>
#include <assert.h>

#define _STRINGIZE(x) #x
#define STRINGIZE(x) _STRINGIZE(x)
#define LINE_STRING STRINGIZE(__LINE__)
#define FUNCTION_STRING STRINGIZE(__FUNCTION__)

#define INFO(msg) fprintf(stderr, "[INFO] %s (" __FILE__ ":" LINE_STRING "): " msg "\n", __func__)
#define WARN(msg) fprintf(stderr, "[WARNING] %s (" __FILE__ ":" LINE_STRING "): " msg "\n", __func__)
#define ERROR(msg) fprintf(stderr, "[ERROR] %s (" __FILE__ ":" LINE_STRING "): " msg "\n", __func__)
#define PERROR(func) perror("[ERROR] " #func " (" __FILE__ ":" LINE_STRING ")")
#define PERRORF() do { \
    char _err_msg[200]; \
    snprintf(_err_msg, sizeof(_err_msg), "[ERROR] %s (" __FILE__ ":" LINE_STRING ")", __func__); \
    perror(_err_msg); \
} while (0)

/*prints a message to stderr and returns a non-zero exit code*/
#define UNREACHABLE(msg) fprintf(stderr, "[ERROR] %s (" __FILE__ ":" LINE_STRING "): " msg "\n", __func__); return 1
/*prints a message to stderr and causes an assertion error*/
#define UNREACHABLE_A(msg) fprintf(stderr, "[ERROR] %s (" __FILE__ ":" LINE_STRING "): " msg "\n", __func__); assert(0 && "Unreachable assert.")

/**
 * Checks an expression for a non-zero return code
 * If the return code is non zero prints ERROR(msg) and returns the provided code
 */
#define CHECK_ERROR(expr, msg, code) if (expr) {ERROR(msg); return code;}
/**
 * Checks an expression for a non-zero return code
 * If the return code is non zero prints PERROR(func) and returns the provided code
 */
#define CHECK_PERROR(expr, func, code) if (expr) {PERROR(func); return code;}

//the below stuff is only really useful if you do many things that could fail in the same way within the same function

#define ERROR_STRING "Unknown - No error provided"
#define ERROR_VALUE 1
/**
 * Checks an expression for a non zero exit code
 * If the return code is non zero prints an error from ERROR_STRING 
 * and returns ERROR_VALUE (default 1)
 * Ideally ERROR_STRING is set before this macro is used, for example
```c
#undef ERROR_STRING
#define ERROR_STRING "Doing Something Failed!"
#undef ERROR_VALUE
#define ERROR_VALUE 2
CHECK_ERR(somethingThatMightFail(1))
CHECK_ERR(somethingThatMightFail(2))
CHECK_ERR(somethingThatMightFail(3))
#undef ERROR_VALUE //only if you later expect the default value of 1
#define ERROR_VALUE 1
```
 * would print an error message with the ERROR_STRING filename and line number
 * before returning 2
 * 
 * `#pragma push_macro ("ERROR_VALUE")` could also be used when setting a custom error value for example
```c
#pragma push_macro ("ERROR_VALUE") //save default value
#undef ERROR_STRING
#undef ERROR_VALUE
#define ERROR_STRING "Doing Something Failed!"
#define ERROR_VALUE 2
CHECK_ERR(somethingThatMightFail(1))
CHECK_ERR(somethingThatMightFail(2))
CHECK_ERR(somethingThatMightFail(3))
#pragma pop_macro ("ERROR_VALUE") //restore default value
```
 */
#define CHECK_ERR(expr) if (expr) {ERROR(ERROR_STRING); return ERROR_VALUE;}
