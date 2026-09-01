#!/bin/bash
STORAGE="/mnt/storage/radio"
JINGLES="no"
ANNOUNCEMENTS="no"
if find "$STORAGE/jingles" -type f \( -name "*.mp3" -o -name "*.m4a" \) 2>/dev/null | grep -q .; then
    JINGLES="yes"
fi
if find "$STORAGE/announcements" -type f \( -name "*.mp3" -o -name "*.m4a" \) 2>/dev/null | grep -q .; then
    ANNOUNCEMENTS="yes"
fi
echo "jingles=$JINGLES" > /srv/radio/dirs.txt
echo "announcements=$ANNOUNCEMENTS" >> /srv/radio/dirs.txt
