"""English legal display and numeric capacity errors keep wire IDs stable."""
from pathlib import Path
from app.main import default_room_title
from conftest import create_room, headers, login
from test_capacity_recovery import limited_lab
from test_room_actions import token


def test_public_english_rendering_matches_the_canonical_consent_manifest(lab):
    path = Path(__file__).resolve().parents[2] / 'shared/legal_documents.json'
    with limited_lab(lab, legal_path=str(path)) as current:
        canonical = current.client.get('/v1/legal/documents').json()
        response = current.client.get('/v1/legal/documents/en')
        assert response.status_code == 200
        assert response.headers['cache-control'] == 'no-store'
        assert response.headers['content-language'] == 'en'
        assert response.json()['sourceDocumentHash'] == canonical['documentHash']
        assert 'documentHash' not in response.json()
        assert not current.client.cookies
        assert len(response.json()['documents']) == 4


def test_numeric_capacity_error_obeys_accept_language_without_changing_status(lab):
    with limited_lab(lab, max_room_participants=8, max_total_participants=16) as small:
        accounts = [login(small, f'User{i}') for i in range(9)]
        room = create_room(small, accounts[0])
        for account in accounts[:8]: token(small, room, account, online=False)
        path = f'/v1/rooms/{room["id"]}/token'
        chinese = small.client.post(path, headers=headers(accounts[-1]))
        english = small.client.post(path, headers={**headers(accounts[-1]), 'Accept-Language':'en'})
        assert chinese.status_code == english.status_code == 409
        assert chinese.json()['detail'] == '房间入场人数已达实验上限8人，请稍后重试'
        assert english.json()['detail'] == 'This room has reached its trial limit of 8 participants. Please try again later.'
        assert small.app.state.db.execute('SELECT COUNT(*) FROM room_members WHERE active=1').fetchone()[0] == 8


def test_generated_room_title_uses_creator_language_without_translating_names(lab):
    account = login(lab, '小明')
    response = lab.client.post('/v1/rooms', headers={**headers(account), 'Accept-Language':'en'},
                               json={'title':'', 'category':'闲聊', 'theme':0, 'isLive':False})
    assert response.status_code == 200
    assert response.json()['title'] == '小明’s room'
    # The saved title is room content and is the same for viewers in either language.
    title = lab.client.get('/v1/rooms/' + response.json()['id'], headers=headers(account)).json()['title']
    assert title == '小明’s room'
    assert default_room_title('', english=True) == 'My room'
    for name in ['🙂' * 80, '名字' * 80, 'a' * 150]:
        title = default_room_title(name, english=True)
        assert len(title) <= 36 and len(title.encode()) <= 100
