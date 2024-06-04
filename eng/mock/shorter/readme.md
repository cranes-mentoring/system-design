"""
### Example URL Shortening System

1. **Requirements:**
   - The service should accept long URLs as input.
   - The service should generate a short URL in response.
   - The generated short URL must be unique and not overlap with other shortened URLs.
   - Shortened URLs should be valid for 1 year.

2. **URL Shortening Algorithm:**
   - We can use the **base62** encoding scheme to generate short URLs.
   - Base62 utilizes a combination of uppercase letters, lowercase letters, and digits (a total of 62 characters).
   - To calculate the minimum number of characters in a short URL, we can use the following formula:
      - `min_chars = ceil(log62(N))`, where `N` is the total number of possible short URLs.
