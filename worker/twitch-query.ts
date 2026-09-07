export const VOD_QUERY = `
    query GetUserVideos($login: String!, $first: Int!, $after: Cursor) {
      user(login: $login) {
        id
        displayName
        login
        videos(first: $first, type: ARCHIVE, after: $after) {
          edges {
            node {
              id
              title
              lengthSeconds
              publishedAt
              game {
                id
                name
                displayName
              }
              moments(first: 25, momentRequestType: VIDEO_CHAPTER_MARKERS) {
                edges {
                  node {
                    positionMilliseconds
                    type
                    description
                    details {
                      ... on GameChangeMomentDetails {
                        game {
                          id
                          name
                          displayName
                        }
                      }
                    }
                  }
                }
              }
            }
            cursor
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
  `;
