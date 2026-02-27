import os

def fix_syntax_in_file(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception as e:
        return False
        
    new_content = content
    if filepath.endswith('.dart'):
        new_content = new_content.replace('class RJ Music', 'class RJMusic')
        new_content = new_content.replace('const RJ Music', 'const RJMusic')
        new_content = new_content.replace(' RJ Music(', ' RJMusic(')
        new_content = new_content.replace('.RJ Music', '.RJMusic')
        new_content = new_content.replace('Search_RJ Music', 'Search_RJMusic')
        new_content = new_content.replace('RJ Music()', 'RJMusic()')
    elif filepath.endswith('.arb'):
        new_content = new_content.replace('"RJ Music":', '"RJMusic":')
        new_content = new_content.replace('"@RJ Music":', '"@RJMusic":')
        new_content = new_content.replace('"Search_RJ Music":', '"Search_RJMusic":')
        new_content = new_content.replace('"@Search_RJ Music":', '"@Search_RJMusic":')

    if new_content != content:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(new_content)
        return True
    return False

root_dir = r'c:\Users\Anand\anime\rj_music'
count = 0
for dirpath, dirnames, filenames in os.walk(root_dir):
    dirnames[:] = [d for d in dirnames if d not in ['.git', 'build', '.dart_tool', '.fvm']]
    for filename in filenames:
        if filename.endswith(('.dart', '.arb')): 
            filepath = os.path.join(dirpath, filename)
            if fix_syntax_in_file(filepath):
                count += 1

print(f'Fixed syntax in {count} files')
